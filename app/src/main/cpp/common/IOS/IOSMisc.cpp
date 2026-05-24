// SPDX-FileCopyrightText: 2002-2025 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#include "common/Assertions.h"
#include "common/BitUtils.h"
#include "common/CrashHandler.h"
#include "common/Error.h"
#include "common/HostSys.h"
#include "common/Threading.h"

#include "fmt/format.h"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach_init.h>
#include <mach/mach_time.h>
#include <mach/mach_host.h>
#include <mutex>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE MAP_FIXED
#endif

static mach_timebase_info_data_t s_timebase_info;
static const u64 s_tick_frequency = []() {
	if (mach_timebase_info(&s_timebase_info) != KERN_SUCCESS)
		std::abort();
	return static_cast<u64>(1000000000ULL) * s_timebase_info.denom / s_timebase_info.numer;
}();

u64 GetTickFrequency()
{
	return s_tick_frequency;
}

u64 GetCPUTicks()
{
	return mach_absolute_time();
}

u64 GetPhysicalMemory()
{
	u64 value = 0;
	size_t size = sizeof(value);
	int mib[] = {CTL_HW, HW_MEMSIZE};
	return (sysctl(mib, std::size(mib), &value, &size, nullptr, 0) == 0) ? value : 0;
}

u64 GetAvailablePhysicalMemory()
{
	const mach_port_t host_port = mach_host_self();
	vm_size_t page_size = 0;
	if (host_page_size(host_port, &page_size) != KERN_SUCCESS)
		return 0;

	vm_statistics64_data_t vm_stat = {};
	mach_msg_type_number_t host_size = sizeof(vm_stat) / sizeof(integer_t);
	if (host_statistics64(host_port, HOST_VM_INFO, reinterpret_cast<host_info64_t>(&vm_stat), &host_size) != KERN_SUCCESS)
		return 0;

	return (static_cast<u64>(vm_stat.free_count) + static_cast<u64>(vm_stat.inactive_count)) * page_size;
}

std::string GetOSVersionString()
{
	char release[64] = {};
	char machine[64] = {};
	size_t release_size = sizeof(release);
	size_t machine_size = sizeof(machine);
	sysctlbyname("kern.osrelease", release, &release_size, nullptr, 0);
	sysctlbyname("hw.machine", machine, &machine_size, nullptr, 0);
	return fmt::format("iOS {} {}", release, machine);
}

void Threading::Sleep(int ms)
{
	usleep(1000 * ms);
}

void Threading::SleepUntil(u64 ticks)
{
	const s64 diff = static_cast<s64>(ticks - GetCPUTicks());
	if (diff <= 0)
		return;

	const u64 nanos = (static_cast<u64>(diff) * s_timebase_info.denom) / s_timebase_info.numer;
	timespec ts = {};
	ts.tv_sec = nanos / 1000000000ULL;
	ts.tv_nsec = nanos % 1000000000ULL;
	nanosleep(&ts, nullptr);
}

bool Common::InhibitScreensaver(bool)
{
	return true;
}

void Common::SetMousePosition(int, int) {}
bool Common::AttachMousePositionCb(std::function<void(int, int)>) { return false; }
void Common::DetachMousePositionCb() {}
bool Common::PlaySoundAsync(const char*) { return false; }

static __ri int IOSProt(const PageProtectionMode& mode)
{
	int prot = 0;
	if (mode.CanRead())
		prot |= PROT_READ;
	if (mode.CanWrite())
		prot |= PROT_WRITE;
	if (mode.CanExecute())
		prot |= PROT_EXEC | PROT_READ;
	return prot;
}

void* HostSys::Mmap(void* base, size_t size, const PageProtectionMode& mode)
{
	if (mode.IsNone())
		return nullptr;

	int flags = MAP_PRIVATE | MAP_ANON;
	if (base)
		flags |= MAP_FIXED_NOREPLACE;
	if (mode.CanExecute())
		flags |= MAP_JIT;

	void* result = mmap(base, size, IOSProt(mode), flags, -1, 0);
	return result == MAP_FAILED ? nullptr : result;
}

void HostSys::Munmap(void* base, size_t size)
{
	if (base)
		munmap(base, size);
}

void HostSys::MemProtect(void* baseaddr, size_t size, const PageProtectionMode& mode)
{
	if (mprotect(baseaddr, size, IOSProt(mode)) != 0)
		pxFail("mprotect() failed");
}

std::string HostSys::GetFileMappingName(const char* prefix)
{
	return fmt::format("/{}_{}", prefix, static_cast<unsigned>(getpid()));
}

void* HostSys::CreateSharedMemory(const char* name, size_t size)
{
	const int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
	if (fd < 0)
		return nullptr;
	shm_unlink(name);
	if (ftruncate(fd, static_cast<off_t>(size)) < 0)
	{
		close(fd);
		return nullptr;
	}
	return reinterpret_cast<void*>(static_cast<intptr_t>(fd));
}

void HostSys::DestroySharedMemory(void* ptr)
{
	close(static_cast<int>(reinterpret_cast<intptr_t>(ptr)));
}

void* HostSys::MapSharedMemory(void* handle, size_t offset, void* baseaddr, size_t size, const PageProtectionMode& mode)
{
	const int flags = (baseaddr != nullptr) ? (MAP_SHARED | MAP_FIXED_NOREPLACE) : MAP_SHARED;
	void* ptr = mmap(baseaddr, size, IOSProt(mode), flags, static_cast<int>(reinterpret_cast<intptr_t>(handle)), static_cast<off_t>(offset));
	return ptr == MAP_FAILED ? nullptr : ptr;
}

void HostSys::UnmapSharedMemory(void* baseaddr, size_t size)
{
	if (munmap(baseaddr, size) != 0)
		pxFailRel("Failed to unmap shared memory");
}

size_t HostSys::GetRuntimePageSize()
{
	const long value = sysconf(_SC_PAGESIZE);
	return value > 0 ? static_cast<size_t>(value) : 0;
}

size_t HostSys::GetRuntimeCacheLineSize()
{
	size_t value = 0;
	size_t size = sizeof(value);
	return (sysctlbyname("hw.cachelinesize", &value, &size, nullptr, 0) == 0) ? value : 64;
}

void HostSys::FlushInstructionCache(void* address, u32 size)
{
	sys_icache_invalidate(address, size);
}

static thread_local int s_code_write_depth = 0;

void HostSys::BeginCodeWrite()
{
	if ((s_code_write_depth++) == 0)
	{
		using JITWriteProtectFunction = void (*)(int);
		static JITWriteProtectFunction fn = reinterpret_cast<JITWriteProtectFunction>(dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
		if (fn)
			fn(0);
	}
}

void HostSys::EndCodeWrite()
{
	pxAssert(s_code_write_depth > 0);
	if ((--s_code_write_depth) == 0)
	{
		using JITWriteProtectFunction = void (*)(int);
		static JITWriteProtectFunction fn = reinterpret_cast<JITWriteProtectFunction>(dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
		if (fn)
			fn(1);
	}
}

SharedMemoryMappingArea::SharedMemoryMappingArea(u8* base_ptr, size_t size, size_t num_pages)
	: m_base_ptr(base_ptr)
	, m_size(size)
	, m_num_pages(num_pages)
{
}

SharedMemoryMappingArea::~SharedMemoryMappingArea()
{
	pxAssertRel(m_num_mappings == 0, "No mappings left");
	munmap(m_base_ptr, m_size);
}

std::unique_ptr<SharedMemoryMappingArea> SharedMemoryMappingArea::Create(size_t size)
{
	void* alloc = mmap(nullptr, size, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (alloc == MAP_FAILED)
		return nullptr;
	return std::unique_ptr<SharedMemoryMappingArea>(new SharedMemoryMappingArea(static_cast<u8*>(alloc), size, size / __pagesize));
}

u8* SharedMemoryMappingArea::Map(void* file_handle, size_t file_offset, void* map_base, size_t map_size, const PageProtectionMode& mode)
{
	void* ptr = mmap(map_base, map_size, IOSProt(mode), MAP_SHARED | MAP_FIXED,
		static_cast<int>(reinterpret_cast<intptr_t>(file_handle)), static_cast<off_t>(file_offset));
	if (ptr == MAP_FAILED)
		return nullptr;
	m_num_mappings++;
	return static_cast<u8*>(ptr);
}

bool SharedMemoryMappingArea::Unmap(void* map_base, size_t map_size)
{
	if (mmap(map_base, map_size, PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == MAP_FAILED)
		return false;
	m_num_mappings--;
	return true;
}

static bool IsStoreInstruction(const void* ptr)
{
	u32 bits;
	std::memcpy(&bits, ptr, sizeof(bits));
	if ((bits & 0x0a000000) != 0x08000000)
		return false;
	if ((bits & 0x3a000000) == 0x28000000)
		return (bits & (1 << 22)) == 0;

	switch (bits & 0xC4C00000)
	{
		case 0x00000000:
		case 0x40000000:
		case 0x80000000:
		case 0xC0000000:
		case 0x04000000:
		case 0x44000000:
		case 0x84000000:
		case 0xC4000000:
		case 0x04800000:
			return true;
		default:
			return false;
	}
}

namespace PageFaultHandler
{
	static void SignalHandler(int sig, siginfo_t* info, void* ctx);
	static std::recursive_mutex s_exception_handler_mutex;
	static bool s_in_exception_handler = false;
	static bool s_installed = false;
}

void PageFaultHandler::SignalHandler(int sig, siginfo_t* info, void* ctx)
{
	void* const exception_address = reinterpret_cast<void*>(info->si_addr);
	void* const exception_pc = reinterpret_cast<void*>(static_cast<ucontext_t*>(ctx)->uc_mcontext->__ss.__pc);
	const bool is_write = IsStoreInstruction(exception_pc);

	s_exception_handler_mutex.lock();
	HandlerResult result = HandlerResult::ExecuteNextHandler;
	if (!s_in_exception_handler)
	{
		s_in_exception_handler = true;
		result = HandlePageFault(exception_pc, exception_address, is_write);
		s_in_exception_handler = false;
	}
	s_exception_handler_mutex.unlock();

	if (result == HandlerResult::ContinueExecution)
		return;

	CrashHandler::CrashSignalHandler(sig, info, ctx);
}

bool PageFaultHandler::Install(Error* error)
{
	std::unique_lock lock(s_exception_handler_mutex);
	if (s_installed)
		return true;

	struct sigaction sa = {};
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_SIGINFO | SA_NODEFER;
	sa.sa_sigaction = SignalHandler;

	if (sigaction(SIGBUS, &sa, nullptr) != 0)
	{
		Error::SetErrno(error, "sigaction() for SIGBUS failed: ", errno);
		return false;
	}
	if (sigaction(SIGSEGV, &sa, nullptr) != 0)
	{
		Error::SetErrno(error, "sigaction() for SIGSEGV failed: ", errno);
		return false;
	}

	s_installed = true;
	return true;
}
