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
#include <mach/vm_map.h>
#include <mutex>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern "C" void AMIOSReinstallMachExceptionHandlerAfterJITDetach();
#include <vector>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE MAP_FIXED
#endif

namespace {

constexpr unsigned AM_IOS_JIT_FLAG_FORCE_MIRRORED = 1u << 1;
constexpr unsigned AM_IOS_JIT_FLAG_HAS_TXM = 1u << 2;
constexpr unsigned AM_IOS_JIT_FLAGS_TXM_MIRRORED = AM_IOS_JIT_FLAG_FORCE_MIRRORED | AM_IOS_JIT_FLAG_HAS_TXM;

struct AMIOSJITMirrorMapping
{
	uintptr_t executable_base;
	uintptr_t write_base;
	size_t size;
};

std::mutex s_jit_mirror_mutex;
std::vector<AMIOSJITMirrorMapping> s_jit_mirror_mappings;

struct AMIOSJITBlessRegion
{
	uintptr_t base;
	size_t size;
	std::vector<uint64_t> blessed_pages; // bit i = page (base + i*4096) blessed
};

std::mutex s_jit_prepared_mutex;
std::vector<AMIOSJITMirrorMapping> s_jit_prepared_ranges;
std::vector<AMIOSJITBlessRegion> s_jit_bless_regions;

void* AMIOSResolveJITWriteAlias(void* address);

bool AMIOSNeedsTXMJITBridge()
{
	using DeviceHasJITFlagsFunction = bool (*)(unsigned);
	static DeviceHasJITFlagsFunction fn = reinterpret_cast<DeviceHasJITFlagsFunction>(dlsym(RTLD_DEFAULT, "DeviceHasJITFlags"));
	return fn && fn(AM_IOS_JIT_FLAGS_TXM_MIRRORED);
}

bool AMIOSJITDiagEnabled()
{
	static const bool enabled = []() {
		const char* value = std::getenv("AM_PS2_JIT_DIAG");
		return value && value[0] != '\0' && std::strcmp(value, "0") != 0 && std::strcmp(value, "false") != 0 &&
			std::strcmp(value, "FALSE") != 0;
	}();
	return enabled;
}

size_t AMIOSJITPageSize()
{
	static const size_t page_size = []() -> size_t {
		const long value = sysconf(_SC_PAGESIZE);
		return value > 0 ? static_cast<size_t>(value) : static_cast<size_t>(16 * 1024);
	}();
	return page_size;
}

std::vector<uint64_t> AMIOSMakeBlessedPageBitmap(size_t size, bool blessed)
{
	const size_t page_size = AMIOSJITPageSize();
	const size_t page_count = (size + page_size - 1u) / page_size;
	const size_t bitmap_words = (page_count + 63u) / 64u;
	std::vector<uint64_t> bitmap(bitmap_words, blessed ? UINT64_MAX : 0);
	if (blessed && !bitmap.empty())
	{
		const size_t tail_bits = page_count & 63u;
		if (tail_bits != 0)
			bitmap.back() = (uint64_t(1) << tail_bits) - 1u;
	}
	return bitmap;
}

void AMIOSDetachJIT26Debugger()
{
	using JIT26DetachFunction = void (*)();
	static JIT26DetachFunction fn = reinterpret_cast<JIT26DetachFunction>(dlsym(RTLD_DEFAULT, "JIT26Detach"));
	if (!fn)
		return;

	if (AMIOSJITDiagEnabled())
		std::fprintf(stderr, "AMPS2 JIT26 detach begin\n");
	fn();
	if (AMIOSJITDiagEnabled())
		std::fprintf(stderr, "AMPS2 JIT26 detach done\n");
	AMIOSReinstallMachExceptionHandlerAfterJITDetach();
}

void AMIOSPrepareExecutableRegion(void* address, size_t size)
{
	if (!address || size == 0 || !AMIOSNeedsTXMJITBridge())
		return;

	using JIT26PrepareRegionFunction = void* (*)(void*, size_t);
	static JIT26PrepareRegionFunction fn = reinterpret_cast<JIT26PrepareRegionFunction>(dlsym(RTLD_DEFAULT, "JIT26PrepareRegion"));
	if (!fn)
		return;

	const size_t page_size = AMIOSJITPageSize();
	const uintptr_t req_start = reinterpret_cast<uintptr_t>(address) & ~(static_cast<uintptr_t>(page_size) - 1u);
	const uintptr_t req_end = (reinterpret_cast<uintptr_t>(address) + size + page_size - 1u) & ~(static_cast<uintptr_t>(page_size) - 1u);

	// Find region containing the request. Use a per-page bitmap inside the region
	// to track exactly which pages are blessed — sub-regions are blessed out of
	// order (mVU at offset 38MB blesses before EE at offset 0) so a watermark
	// would incorrectly skip the lower addresses.
	//
	// Diag (1.0.224) confirmed: vm_remap RW alias is immediately RX-visible
	// (rx_before == rw_before before any post-write bless). So bless is purely
	// a one-time "make this page available via RW alias for patching" op; once
	// a page has been blessed it never needs to be re-blessed. Per-page bitmap
	// dedup is therefore SAFE and is the primary perf win: armEndBlock no
	// longer re-blesses pages already covered by the 256KB pre-bless from
	// armStartBlock.
	AMIOSJITBlessRegion* region = nullptr;
	std::vector<uintptr_t> pages_to_bless;
	{
		std::lock_guard<std::mutex> lock(s_jit_prepared_mutex);
		for (AMIOSJITBlessRegion& r : s_jit_bless_regions)
		{
			if (req_start >= r.base && req_end <= (r.base + r.size))
			{
				region = &r;
				break;
			}
		}
		if (region)
		{
			const size_t region_pages = (region->size + page_size - 1u) / page_size;
			const size_t bitmap_words = (region_pages + 63) / 64;
			if (region->blessed_pages.size() < bitmap_words)
				region->blessed_pages.resize(bitmap_words, 0);
			for (uintptr_t p = req_start; p < req_end; p += page_size)
			{
				const size_t page_idx = (p - region->base) / page_size;
				const size_t word = page_idx / 64;
				const uint64_t bit = uint64_t(1) << (page_idx & 63);
				if (region->blessed_pages[word] & bit)
					continue;
				region->blessed_pages[word] |= bit;
				pages_to_bless.push_back(p);
			}
		}
		else
		{
			// Outside any known region — legacy dedup path.
			for (const AMIOSJITMirrorMapping& range : s_jit_prepared_ranges)
			{
				const uintptr_t range_end = range.executable_base + range.size;
				if (req_start >= range.executable_base && req_end <= range_end)
					return;
			}
		}
	}

	static int log_count = 0;
	const int my_count = AMIOSJITDiagEnabled() ? log_count++ : 256;

	if (region)
	{
		if (pages_to_bless.empty())
			return;

		// Bless only never-before-blessed pages. This must run before writing
		// code into the RW alias, because command 1's TXM page touch writes a
		// marker byte into the page.
		uintptr_t run_start = pages_to_bless.front();
		uintptr_t previous = run_start;
		auto flush_run = [&]() {
			const size_t run_size = static_cast<size_t>((previous - run_start) + page_size);
			if (my_count < 256)
				std::fprintf(stderr, "AMPS2 JIT26 prebless call #%d address=%p size=%zu\n",
					my_count, reinterpret_cast<void*>(run_start), run_size);
			fn(reinterpret_cast<void*>(run_start), run_size);
			if (my_count < 256)
				std::fprintf(stderr, "AMPS2 JIT26 prebless done #%d address=%p size=%zu\n",
					my_count, reinterpret_cast<void*>(run_start), run_size);
		};
		for (size_t i = 1; i < pages_to_bless.size(); i++)
		{
			const uintptr_t p = pages_to_bless[i];
			if (p == previous + page_size)
			{
				previous = p;
				continue;
			}
			flush_run();
			run_start = previous = p;
		}
		flush_run();
		if (my_count < 256)
			std::fprintf(stderr, "AMPS2 JIT26 prebless #%d first=%p last=%p pages=%zu region=%p (dedup)\n",
				my_count, reinterpret_cast<void*>(pages_to_bless.front()),
				reinterpret_cast<void*>(pages_to_bless.back()), pages_to_bless.size(),
				reinterpret_cast<void*>(region->base));
		return;
	}

	// Region-less path: bless whole request once.
	const size_t bless_size = static_cast<size_t>(req_end - req_start);
	if (my_count < 64)
		std::fprintf(stderr, "AMPS2 JIT26 prebless-uncached #%d address=%p size=%zu\n",
			my_count, reinterpret_cast<void*>(req_start), bless_size);
	fn(reinterpret_cast<void*>(req_start), bless_size);
	if (my_count < 64)
		std::fprintf(stderr, "AMPS2 JIT26 prebless-uncached done #%d address=%p size=%zu\n",
			my_count, reinterpret_cast<void*>(req_start), bless_size);
	{
		std::lock_guard<std::mutex> lock(s_jit_prepared_mutex);
		s_jit_prepared_ranges.push_back({req_start, 0, bless_size});
	}
}

extern "C" void AMIOSPrepareJITRegion(void* address, size_t size)
{
	AMIOSPrepareExecutableRegion(address, size);
}

void* AMIOSResolveJITWriteAlias(void* address)
{
	const uintptr_t value = reinterpret_cast<uintptr_t>(address);
	std::lock_guard lock(s_jit_mirror_mutex);
	for (const AMIOSJITMirrorMapping& mapping : s_jit_mirror_mappings)
	{
		if (value >= mapping.executable_base && value < mapping.executable_base + mapping.size)
			return reinterpret_cast<void*>(mapping.write_base + (value - mapping.executable_base));
	}
	return address;
}

void AMIOSRegisterJITWriteAlias(void* executable_base, size_t size)
{
	if (!executable_base || size == 0 || !AMIOSNeedsTXMJITBridge())
		return;

	vm_address_t write_base = 0;
	vm_prot_t current_protection = 0;
	vm_prot_t max_protection = 0;
	const kern_return_t remap_result = vm_remap(
		mach_task_self(), &write_base, size, 0, VM_FLAGS_ANYWHERE,
		mach_task_self(), reinterpret_cast<vm_address_t>(executable_base), false,
		&current_protection, &max_protection, VM_INHERIT_SHARE);
	if (remap_result != KERN_SUCCESS)
	{
		std::fprintf(stderr, "AMPS2 JIT26 mirror remap failed result=%d address=%p size=%zu\n",
			remap_result, executable_base, size);
		return;
	}

	const kern_return_t protect_result = vm_protect(mach_task_self(), write_base, size, false, VM_PROT_READ | VM_PROT_WRITE);
	if (protect_result != KERN_SUCCESS)
	{
		std::fprintf(stderr, "AMPS2 JIT26 mirror protect failed result=%d address=%p write=%p size=%zu\n",
			protect_result, executable_base, reinterpret_cast<void*>(write_base), size);
		vm_deallocate(mach_task_self(), write_base, size);
		return;
	}

	{
		std::lock_guard lock(s_jit_mirror_mutex);
		s_jit_mirror_mappings.push_back({
			reinterpret_cast<uintptr_t>(executable_base),
			static_cast<uintptr_t>(write_base),
			size,
		});
	}

	static int log_count = 0;
	if (AMIOSJITDiagEnabled() && log_count++ < 8)
		std::fprintf(stderr, "AMPS2 JIT26 mirror executable=%p write=%p size=%zu\n",
			executable_base, reinterpret_cast<void*>(write_base), size);
}

void AMIOSUnregisterJITWriteAlias(void* executable_base)
{
	if (!executable_base)
		return;

	const uintptr_t value = reinterpret_cast<uintptr_t>(executable_base);
	{
		std::lock_guard lock(s_jit_mirror_mutex);
		for (auto it = s_jit_mirror_mappings.begin(); it != s_jit_mirror_mappings.end(); ++it)
		{
			if (it->executable_base == value)
			{
				vm_deallocate(mach_task_self(), static_cast<vm_address_t>(it->write_base), it->size);
				s_jit_mirror_mappings.erase(it);
				break;
			}
		}
	}

	{
		std::lock_guard prepared_lock(s_jit_prepared_mutex);
		const uintptr_t value = reinterpret_cast<uintptr_t>(executable_base);
		for (auto it = s_jit_prepared_ranges.begin(); it != s_jit_prepared_ranges.end();)
		{
			if (it->executable_base == value)
				it = s_jit_prepared_ranges.erase(it);
			else
				++it;
		}
		for (auto it = s_jit_bless_regions.begin(); it != s_jit_bless_regions.end();)
		{
			if (it->base == value)
				it = s_jit_bless_regions.erase(it);
			else
				++it;
		}
	}
}

void* AMIOSCreateExecutableRegion(size_t size)
{
	if (size == 0 || !AMIOSNeedsTXMJITBridge())
		return nullptr;

	using JIT26PrepareRegionFunction = void* (*)(void*, size_t);
	static JIT26PrepareRegionFunction fn = reinterpret_cast<JIT26PrepareRegionFunction>(dlsym(RTLD_DEFAULT, "JIT26PrepareRegion"));
	if (!fn)
		return nullptr;

	void* prepared = fn(nullptr, size);
	static int log_count = 0;
	if (AMIOSJITDiagEnabled() && log_count++ < 8)
		std::fprintf(stderr, "AMPS2 JIT26 allocate executable size=%zu result=%p\n", size, prepared);
	return prepared;
}

void AMIOSPatchExecutableRegion(void* address, size_t size)
{
	if (!address || size == 0 || !AMIOSNeedsTXMJITBridge())
		return;

	using JIT26PrepareRegionForPatchingFunction = void (*)(void*, size_t);
	static JIT26PrepareRegionForPatchingFunction fn = reinterpret_cast<JIT26PrepareRegionForPatchingFunction>(dlsym(RTLD_DEFAULT, "JIT26PrepareRegionForPatching"));
	if (!fn)
		return;

	static int log_count = 0;
	fn(address, size);
	if (AMIOSJITDiagEnabled() && log_count++ < 16)
		std::fprintf(stderr, "AMPS2 JIT26 patch region address=%p size=%zu\n", address, size);
}

} // namespace

extern "C" void* AMIOSGetJITWriteAlias(void* address)
{
	return AMIOSResolveJITWriteAlias(address);
}

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

	const bool executable = mode.CanExecute();
	const bool txm_jit = executable && AMIOSNeedsTXMJITBridge();

	// On iOS 26 TXM: a plain mmap(MAP_ANON) page can never be granted exec via JIT26
	// bless-mode (per-page `M<addr>,1:69`). The only path that actually grants TXM exec
	// is the `_M<size>,rx` allocation packet, which we drive via JIT26PrepareRegion(NULL, size).
	// Use that for any executable+TXM allocation at NULL base. Callers that pin `base` will
	// fall through to the plain mmap path (and likely fault on exec — there's no way to
	// retroactively bless a chosen address on iOS 26 TXM Personal Team builds).
	if (txm_jit && !base)
	{
		using JIT26PrepareRegionFunction = void* (*)(void*, size_t);
		static JIT26PrepareRegionFunction fn = reinterpret_cast<JIT26PrepareRegionFunction>(dlsym(RTLD_DEFAULT, "JIT26PrepareRegion"));
		if (fn)
		{
			if (AMIOSJITDiagEnabled())
				std::fprintf(stderr, "AMPS2 HostSys::Mmap _M-alloc begin size=%zu\n", size);
			void* alloc = fn(nullptr, size);
			if (AMIOSJITDiagEnabled())
				std::fprintf(stderr, "AMPS2 HostSys::Mmap _M-alloc result=%p size=%zu\n", alloc, size);
			if (alloc)
			{
				// _M<size>,rx returns pages that need per-page bless before exec.
				// The bless writes 0x69 at byte 0 of each page, so we MUST bless
				// pages BEFORE the recompiler writes code to them. Strategy:
				//   1. Register the region with an empty page bitmap.
				//   2. Recompiler calls AMIOSPrepareExecutableRegion before writing;
				//      that blesses only pages not already covered by the bitmap.
				//   3. The post-write FlushInstructionCache only invalidates i-cache.
				AMIOSRegisterJITWriteAlias(alloc, size);
				{
					std::lock_guard<std::mutex> lock(s_jit_prepared_mutex);
					// The PS2 module extension preblesses the whole `_M` allocation
					// before returning it, then detaches SideStore. Runtime JIT writes
					// must therefore stay local and never trigger another BRK.
					s_jit_bless_regions.push_back({
						reinterpret_cast<uintptr_t>(alloc),
						size,
						AMIOSMakeBlessedPageBitmap(size, true),
					});
				}
				if (AMIOSJITDiagEnabled())
					std::fprintf(stderr, "AMPS2 JIT26 region registered preblessed base=%p size=%zu page=%zu\n",
						alloc, size, AMIOSJITPageSize());
				AMIOSDetachJIT26Debugger();
				return alloc;
			}

			std::fprintf(stderr, "AMPS2 HostSys::Mmap _M-alloc failed; refusing plain executable mmap on TXM\n");
			return nullptr;
		}

		std::fprintf(stderr, "AMPS2 HostSys::Mmap JIT26PrepareRegion symbol missing; refusing plain executable mmap on TXM\n");
		return nullptr;
	}

	int flags = MAP_PRIVATE | MAP_ANON;
	if (base)
		flags |= MAP_FIXED_NOREPLACE;
	if (executable && !txm_jit)
		flags |= MAP_JIT;

	if (AMIOSJITDiagEnabled())
		std::fprintf(stderr, "AMPS2 HostSys::Mmap begin base=%p size=%zu exec=%d txm=%d\n",
			base, size, executable ? 1 : 0, txm_jit ? 1 : 0);
	void* result = mmap(base, size, IOSProt(mode), flags, -1, 0);
	if (AMIOSJITDiagEnabled())
		std::fprintf(stderr, "AMPS2 HostSys::Mmap mmap done result=%p\n", result);
	if (result == MAP_FAILED && executable && (flags & MAP_JIT))
	{
		const int jit_errno = errno;
		const int fallback_flags = flags & ~MAP_JIT;
		result = mmap(base, size, IOSProt(mode), fallback_flags, -1, 0);
		if (result == MAP_FAILED)
			std::fprintf(stderr, "HostSys::Mmap executable allocation failed: MAP_JIT errno=%d fallback errno=%d size=%zu\n",
				jit_errno, errno, size);
	}
	if (result == MAP_FAILED)
		return nullptr;

	if (executable)
	{
		if (mprotect(result, size, IOSProt(mode)) != 0)
			std::fprintf(stderr, "HostSys::Mmap executable mprotect failed errno=%d address=%p size=%zu txm=%d\n",
				errno, result, size, txm_jit ? 1 : 0);
	}

	return result;
}

void HostSys::Munmap(void* base, size_t size)
{
	if (base)
	{
		AMIOSUnregisterJITWriteAlias(base);
		munmap(base, size);
	}
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
	int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
	const bool using_shm = (fd >= 0);
	if (fd < 0)
	{
		const char* tmpdir = std::getenv("TMPDIR");
		std::string path = fmt::format("{}/pcsx2-shm-XXXXXX", (tmpdir && tmpdir[0] != '\0') ? tmpdir : "/tmp");
		fd = mkstemp(path.data());
		if (fd >= 0)
			unlink(path.c_str());
	}
	if (fd < 0)
		return nullptr;

	if (using_shm)
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
	static int diag_count = 0;
	const bool diag_on = (diag_count < 64) && AMIOSNeedsTXMJITBridge() && AMIOSJITDiagEnabled();
	void* write_alias = diag_on ? AMIOSResolveJITWriteAlias(address) : nullptr;
	u32 rx_before = 0, rw_before = 0;
	if (diag_on)
	{
		std::memcpy(&rx_before, address, sizeof(rx_before));
		if (write_alias)
			std::memcpy(&rw_before, write_alias, sizeof(rw_before));
	}
	sys_icache_invalidate(address, size);
	if (diag_on)
	{
		u32 rx_after = 0;
		std::memcpy(&rx_after, address, sizeof(rx_after));
		std::fprintf(stderr, "AMPS2 flush diag #%d addr=%p size=%u rx_before=%08x rw_before=%08x rx_after=%08x\n",
			diag_count, address, size, rx_before, rw_before, rx_after);
		diag_count++;
	}
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
