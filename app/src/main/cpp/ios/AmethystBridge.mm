#include "common/FileSystem.h"
#include "common/Console.h"
#include "common/HostSys.h"
#include "common/Path.h"
#include "common/SettingsInterface.h"
#include "common/StringUtil.h"
#include "common/WindowInfo.h"

#include "pcsx2/Achievements.h"
#include "pcsx2/Config.h"
#include "pcsx2/Counters.h"
#include "pcsx2/GS.h"
#include "pcsx2/GS/GSPerfMon.h"
#include "pcsx2/Host.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/Hw.h"
#include "pcsx2/IopHw.h"
#include "pcsx2/IopMem.h"
#include "pcsx2/Memory.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/Patch.h"
#include "pcsx2/R3000A.h"
#include "pcsx2/R5900.h"
#include "pcsx2/ps2/BiosTools.h"
#include "pcsx2/DebugTools/BiosDebugData.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/CDVD/CDVD.h"
#include "pcsx2/CDVD/CDVDcommon.h"
#include "pcsx2/DebugTools/Debug.h"
#include "pcsx2/Dmac.h"
#include "pcsx2/Gif_Unit.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadDualshock2.h"
#include "pcsx2/SIO/Memcard/MemoryCardFile.h"
#include "pcsx2/VU.h"
#include "pcsx2/Vif_Dma.h"
#include "pcsx2/VifDef.h"

#include "GSDumpReplayer.h"
#include "PerformanceMetrics.h"

#include <UIKit/UIKit.h>
#include <Security/Security.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <os/proc.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <deque>
#include <exception>
#include <fstream>
#include <functional>
#include <memory>
#include <csignal>
#include <sys/ucontext.h>
#include <unistd.h>

extern "C" void AMIOSInstallMachExceptionHandler();
#include <mutex>
#include <optional>
#include <string>
#include <thread>

extern std::atomic<int> g_amethyst_ee_event_stage;
extern "C" u32 g_amethyst_jit_marker = 0;
// AMPS2: JIT dispatcher LDR diagnostic - written from JIT before BR
extern "C" uint64_t g_amps2_jit_dispatch_pc = 0;
extern "C" uint64_t g_amps2_jit_dispatch_rcx = 0;
extern "C" uint64_t g_amps2_jit_dispatch_rax = 0;
extern "C" uint64_t g_amps2_jit_dispatch_count = 0;
extern "C" uint8_t g_amps2_jit_dispatch_cpu = 0; // 0=EE, 1=IOP
extern "C" void* AMIOSGetJITWriteAlias(void* address);
extern "C" void AMIOSPrepareJITRegion(void* address, size_t size);

extern uint64_t g_amps2_iop_intc_count[32];
extern "C" uint64_t g_amps2_ee_intc_count[32];
extern "C" uint64_t g_amps2_sif0_dma_count;
extern "C" uint64_t g_amps2_sif0_iop_xfer;
extern "C" uint64_t g_amps2_sif0_ee_xfer;
extern "C" uint64_t g_amps2_sif0_endee;
extern "C" uint64_t g_amps2_sif0_endiop;
extern "C" uint64_t g_amps2_sif0_eetag;
extern "C" uint64_t g_amps2_sif0_eetag_end;
extern "C" uint64_t g_amps2_sif0_eeirq;
extern "C" uint64_t g_amps2_sif1_dma_count;
extern BiosDebugInformation CurrentBiosInformation;

namespace
{
std::unique_ptr<INISettingsInterface> s_settings_interface;
std::mutex s_bridge_mutex;
std::thread s_vm_thread;
std::thread s_diagnostics_thread;
std::atomic_bool s_initialized{false};
std::atomic_bool s_booting{false};
std::atomic_bool s_running{false};
std::atomic_bool s_stop_requested{false};
std::atomic_bool s_diagnostics_stop{false};
std::string s_last_error;
std::string s_data_root;
std::string s_resources_root;
UIView* s_render_view = nil;
std::mutex s_cpu_task_mutex;
std::deque<std::function<void()>> s_cpu_tasks;
thread_local bool t_on_cpu_thread = false;

#define AMETHYST_EXPORT extern "C" __attribute__((visibility("default")))

static void AppendBridgeLog(const std::string& message);
static void EnsureDirectory(const std::string& path);
static bool RunJITSmokeTest();
static void StartDiagnosticsThread();
static void StopDiagnosticsThread();

static std::string Hex32(u32 value)
{
	return StringUtil::StdStringFromFormat("%08X", value);
}

static std::string Hex64(uint64_t value)
{
	return StringUtil::StdStringFromFormat("%016llX", (unsigned long long)value);
}

static std::string Hex16(u32 value)
{
	return StringUtil::StdStringFromFormat("%04X", value);
}

static const char* RendererName(GSRendererType renderer)
{
	return Pcsx2Config::GSOptions::GetRendererName(renderer);
}

static GSRendererType SelectedGSRenderer()
{
	const char* renderer_env = std::getenv("AM_PS2_RENDERER");
	const std::string renderer = renderer_env ? StringUtil::toLower(std::string(renderer_env)) : std::string();
	if (renderer == "sw" || renderer == "software")
		return GSRendererType::SW;
	if (renderer == "metal")
		return GSRendererType::Metal;

	id renderer_setting = [NSUserDefaults.standardUserDefaults objectForKey:@"AMPS2Renderer"];
	if (renderer_setting && [NSUserDefaults.standardUserDefaults integerForKey:@"AMPS2Renderer"] == 1)
		return GSRendererType::SW;

	return GSRendererType::Metal;
}

static AudioBackend SelectedAudioBackend()
{
	const char* backend_env = std::getenv("AM_PS2_AUDIO_BACKEND");
	const std::string backend = backend_env ? StringUtil::toLower(std::string(backend_env)) : std::string();
	if (backend == "null" || backend == "none" || backend == "off")
		return AudioBackend::Null;
	return AudioBackend::SDL;
}

struct CPUProfile
{
	std::string name;
	s32 core_type;
	bool use_arm64_dynarec;
	bool enable_ee_recompiler;
	bool enable_iop_recompiler;
	bool enable_vu0_recompiler;
	bool enable_vu1_recompiler;
	bool prefer_accuracy_speedhacks;
};

static std::string EnvString(const char* key)
{
	const char* value = std::getenv(key);
	return value ? StringUtil::toLower(std::string(value)) : std::string();
}

static void SetCPUProfileTimingLabel(CPUProfile& profile, bool prefer_accuracy_speedhacks)
{
	const std::string accurate = " + accurate timing";
	const std::string fast = " + speedhacks";
	if (const size_t pos = profile.name.find(accurate); pos != std::string::npos)
		profile.name.erase(pos, accurate.size());
	if (const size_t pos = profile.name.find(fast); pos != std::string::npos)
		profile.name.erase(pos, fast.size());
	profile.name += prefer_accuracy_speedhacks ? accurate : fast;
}

static CPUProfile ApplyCPUEnvironmentOverrides(CPUProfile profile)
{
	const std::string iop = EnvString("AM_PS2_IOP");
	if (iop == "0" || iop == "off" || iop == "int" || iop == "interpreter" || iop == "safe")
	{
		profile.enable_iop_recompiler = false;
		profile.name += " + IOP interpreter";
	}
	else if (iop == "1" || iop == "on" || iop == "jit" || iop == "rec" || iop == "recompiler")
	{
		profile.enable_iop_recompiler = true;
		profile.name += " + IOP rec";
	}

	const auto apply_vu_override = [](const std::string& value, bool* enabled) -> bool {
		if (value == "0" || value == "off" || value == "int" || value == "interpreter" || value == "safe")
		{
			*enabled = false;
			return true;
		}
		if (value == "1" || value == "on" || value == "jit" || value == "rec" || value == "recompiler")
		{
			*enabled = true;
			return true;
		}
		return false;
	};

	const std::string vu = EnvString("AM_PS2_VU");
	if (apply_vu_override(vu, &profile.enable_vu0_recompiler))
	{
		apply_vu_override(vu, &profile.enable_vu1_recompiler);
		profile.name += profile.enable_vu0_recompiler ? " + VU rec" : " + VU interpreter";
	}

	const std::string vu0 = EnvString("AM_PS2_VU0");
	if (apply_vu_override(vu0, &profile.enable_vu0_recompiler))
		profile.name += profile.enable_vu0_recompiler ? " + VU0 rec" : " + VU0 interpreter";

	const std::string vu1 = EnvString("AM_PS2_VU1");
	if (apply_vu_override(vu1, &profile.enable_vu1_recompiler))
		profile.name += profile.enable_vu1_recompiler ? " + VU1 rec" : " + VU1 interpreter";

	const std::string speedhacks = EnvString("AM_PS2_SPEEDHACKS");
	if (speedhacks == "0" || speedhacks == "off" || speedhacks == "accurate" || speedhacks == "safe")
	{
		profile.prefer_accuracy_speedhacks = true;
		SetCPUProfileTimingLabel(profile, true);
	}
	else if (speedhacks == "1" || speedhacks == "on" || speedhacks == "fast")
	{
		profile.prefer_accuracy_speedhacks = false;
		SetCPUProfileTimingLabel(profile, false);
	}

	return profile;
}

static CPUProfile LegacyTranslatorCPUProfile(bool prefer_accuracy_speedhacks = false)
{
	return {
		prefer_accuracy_speedhacks ? "JIT translator(recCpu) + IOP/VU interpreter + accurate timing" : "JIT translator(recCpu) + IOP/VU interpreter",
		0,
		false,
		true,
		false,
		false,
		false,
		prefer_accuracy_speedhacks,
	};
}

static std::string ARM64DynarecCPUProfileName(bool prefer_accuracy_speedhacks, bool enable_iop_recompiler, bool enable_vu0_recompiler, bool enable_vu1_recompiler)
{
	std::string name = "ARM64 dynarec";
	name += enable_iop_recompiler ? " + IOP rec" : " + IOP interpreter";
	name += enable_vu0_recompiler ? " + VU0 rec" : " + VU0 interpreter";
	name += enable_vu1_recompiler ? " + VU1 rec" : " + VU1 interpreter";
	name += prefer_accuracy_speedhacks ? " + accurate timing" : " + speedhacks";
	return name;
}

static CPUProfile ARM64DynarecCPUProfile(
	bool prefer_accuracy_speedhacks = false,
	bool enable_iop_recompiler = true,
	bool enable_vu0_recompiler = true,
	bool enable_vu1_recompiler = true)
{
	return {
		ARM64DynarecCPUProfileName(prefer_accuracy_speedhacks, enable_iop_recompiler, enable_vu0_recompiler, enable_vu1_recompiler),
		2,
		true,
		true,
		enable_iop_recompiler,
		enable_vu0_recompiler,
		enable_vu1_recompiler,
		prefer_accuracy_speedhacks,
	};
}

static CPUProfile SelectedCPUProfile(GSRendererType renderer)
{
	std::string cpu = EnvString("AM_PS2_CPU");
	if (cpu.empty())
	{
		id cpu_setting = [NSUserDefaults.standardUserDefaults objectForKey:@"AMPS2CPUProfile"];
		if ([cpu_setting isKindOfClass:NSString.class])
			cpu = StringUtil::toLower(std::string([(NSString*)cpu_setting UTF8String]));
		else if (cpu_setting)
		{
			switch ([NSUserDefaults.standardUserDefaults integerForKey:@"AMPS2CPUProfile"])
			{
				case 1:
					cpu = "interpreter";
					break;
				case 2:
					cpu = "arm64";
					break;
				default:
					cpu = "jit";
					break;
			}
		}
	}

	if (cpu == "translator" || cpu == "recpu" || cpu == "legacy")
		return ApplyCPUEnvironmentOverrides(LegacyTranslatorCPUProfile());
	if (cpu == "translator-safe" || cpu == "recpu-safe" || cpu == "legacy-safe")
		return ApplyCPUEnvironmentOverrides(LegacyTranslatorCPUProfile(true));
	if (cpu == "jit" || cpu == "rec" || cpu == "recompiler")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile());
	if (cpu == "jit-iopint" || cpu == "jit-iop-interpreter" || cpu == "rec-iopint")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile(false, false, true, true));
	if (cpu == "jit-safe" || cpu == "rec-safe")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile(true));
	if (cpu == "arm64" || cpu == "a64")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile());
	if (cpu == "arm64-iopint" || cpu == "a64-iopint" || cpu == "arm64-iop-interpreter")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile(false, false, true, true));
	if (cpu == "arm64-safe" || cpu == "a64-safe")
		return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile(true));
	if (cpu == "int" || cpu == "interpreter" || cpu == "safe")
		return ApplyCPUEnvironmentOverrides({"Interpreter", 1, false, false, false, false, false, true});

	return ApplyCPUEnvironmentOverrides(ARM64DynarecCPUProfile());
}

static const char* AudioBackendName(AudioBackend backend)
{
	switch (backend)
	{
		case AudioBackend::SDL:
			return "SDL";
		case AudioBackend::Cubeb:
			return "Cubeb";
		case AudioBackend::Null:
			return "Null";
		default:
			return "Unknown";
	}
}

static bool HasBooleanEntitlement(NSString* entitlement)
{
	using CreateFromSelfFunction = void* (*)(CFAllocatorRef);
	using CopyValueFunction = CFTypeRef (*)(void*, CFStringRef, CFErrorRef*);
	static void* security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
	static CreateFromSelfFunction create_from_self = reinterpret_cast<CreateFromSelfFunction>(
		dlsym(security ? security : RTLD_DEFAULT, "SecTaskCreateFromSelf"));
	static CopyValueFunction copy_value = reinterpret_cast<CopyValueFunction>(
		dlsym(security ? security : RTLD_DEFAULT, "SecTaskCopyValueForEntitlement"));
	if (!create_from_self || !copy_value)
		return false;

	void* task = create_from_self(kCFAllocatorDefault);
	if (!task)
		return false;

	CFErrorRef error = nullptr;
	CFTypeRef value = copy_value(task, (__bridge CFStringRef)entitlement, &error);
	CFRelease(static_cast<CFTypeRef>(task));
	if (error)
		CFRelease(error);
	if (!value)
		return false;

	const bool enabled = CFGetTypeID(value) == CFBooleanGetTypeID() &&
		CFBooleanGetValue(static_cast<CFBooleanRef>(value));
	CFRelease(value);
	return enabled;
}

static std::string DecodeEEInstruction(u32 pc)
{
	u32 code = 0;
	if (!vtlb_memSafeReadBytes(pc, &code, sizeof(code)))
		return "unmapped";

	std::string disasm;
	R5900::disR5900Fasm(disasm, code, pc, true);
	return "0x" + Hex32(code) + " " + disasm;
}

static std::string ReadEEU32(u32 address)
{
	u32 value = 0;
	if (!vtlb_memSafeReadBytes(address, &value, sizeof(value)))
		return "unmapped";

	return "0x" + Hex32(value);
}

static std::string ReadEEU8(u32 address)
{
	u8 value = 0;
	if (!vtlb_memSafeReadBytes(address, &value, sizeof(value)))
		return "unmapped";

	return "0x" + Hex16(value);
}

static bool UserBool(NSString* key, bool default_value)
{
	id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
	return value ? [NSUserDefaults.standardUserDefaults boolForKey:key] : default_value;
}

static bool EnvBool(const char* key, bool default_value = false)
{
	const char* value = std::getenv(key);
	if (!value || value[0] == '\0')
		return default_value;

	const std::string normalized = StringUtil::toLower(std::string(value));
	return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on";
}

static int UserInt(NSString* key, int default_value)
{
	id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
	return value ? static_cast<int>([NSUserDefaults.standardUserDefaults integerForKey:key]) : default_value;
}

static const char* AspectRatioNameForIndex(int index)
{
	index = std::clamp(index, 0, static_cast<int>(AspectRatioType::MaxCount) - 1);
	return Pcsx2Config::GSOptions::AspectRatioNames[index];
}

static void SetLastError(std::string error)
{
	std::lock_guard lock(s_bridge_mutex);
	s_last_error = std::move(error);
	if (!s_last_error.empty())
		AppendBridgeLog(s_last_error);
}

static std::string StringFromCString(const char* value)
{
	return value ? std::string(value) : std::string();
}

static void AppendBridgeLog(const std::string& message)
{
	NSLog(@"[ARMSX2] %s", message.c_str());

	NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	NSString* timestamp = [formatter stringFromDate:NSDate.date];
	const std::string line = std::string(timestamp.UTF8String) + " [ARMSX2] " + message + "\n";

	if (!s_data_root.empty())
	{
		EnsureDirectory(s_data_root + "/Logs");
		std::ofstream stream(s_data_root + "/Logs/armsx2-amethyst.log", std::ios::app);
		if (stream)
			stream << line;
	}

	NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	if (documents.length > 0)
	{
		std::string app_log_root = std::string(documents.UTF8String) + "/ps2/Logs";
		EnsureDirectory(app_log_root);
		std::ofstream app_stream(app_log_root + "/armsx2-amethyst.log", std::ios::app);
		if (app_stream)
			app_stream << line;
	}
}

static void AppendCoreLog(LOGLEVEL level, ConsoleColors color, std::string_view message)
{
	(void)level;
	(void)color;
	if (message.empty())
		return;

	AppendBridgeLog("CORE " + std::string(message));
}

static void EnsureDirectory(const std::string& path)
{
	if (!path.empty())
		FileSystem::CreateDirectoryPath(path.c_str(), false);
}

static bool RunJITSmokeTest()
{
	constexpr size_t page_size = 16 * 1024;
	AppendBridgeLog("JIT smoke begin");
	void* executable = HostSys::Mmap(nullptr, page_size, PageAccess_ExecOnly());
	AppendBridgeLog("JIT smoke allocated exec=" + std::to_string(reinterpret_cast<uintptr_t>(executable)));
	if (!executable)
	{
		AppendBridgeLog("JIT smoke failed: executable allocation returned null");
		return false;
	}

	void* writable = AMIOSGetJITWriteAlias(executable);
	AppendBridgeLog("JIT smoke alias write=" + std::to_string(reinterpret_cast<uintptr_t>(writable)));
	if (!writable)
	{
		AppendBridgeLog("JIT smoke failed: write alias returned null");
		HostSys::Munmap(executable, page_size);
		return false;
	}

	constexpr u32 code[] = {
		0xD50324DFu, // bti jc
		0x52995FC8u, // mov w8, #0xcafe
		0xB9000008u, // str w8, [x0]
		0x52800A20u, // mov w0, #0x51
		0xD65F03C0u, // ret
	};

	AppendBridgeLog("JIT smoke prebless code");
	AMIOSPrepareJITRegion(executable, sizeof(code));
	AppendBridgeLog("JIT smoke write code");
	std::memcpy(writable, code, sizeof(code));
	AppendBridgeLog("JIT smoke flush code");
	HostSys::FlushInstructionCache(executable, sizeof(code));

	g_amethyst_jit_marker = 0;
	using SmokeFunction = u32 (*)(u32*);
	SmokeFunction fn = reinterpret_cast<SmokeFunction>(executable);
	AppendBridgeLog("JIT smoke call");
	const u32 result = fn(&g_amethyst_jit_marker);
	const bool ok = (result == 0x51u && g_amethyst_jit_marker == 0xcafeu);
	AppendBridgeLog("JIT smoke " + std::string(ok ? "ok" : "failed") +
		" exec=" + std::to_string(reinterpret_cast<uintptr_t>(executable)) +
		" write=" + std::to_string(reinterpret_cast<uintptr_t>(writable)) +
		" result=0x" + Hex32(result) +
		" marker=0x" + Hex32(g_amethyst_jit_marker));

	HostSys::Munmap(executable, page_size);
	return ok;
}

static void EnqueueCPUThreadTask(std::function<void()> task)
{
	std::lock_guard lock(s_cpu_task_mutex);
	s_cpu_tasks.push_back(std::move(task));
}

static void DrainCPUThreadTasks()
{
	std::deque<std::function<void()>> tasks;
	{
		std::lock_guard lock(s_cpu_task_mutex);
		tasks.swap(s_cpu_tasks);
	}

	for (std::function<void()>& task : tasks)
		task();
}

static std::optional<WindowInfo> WindowInfoForView(UIView* view)
{
	if (!view)
	{
		AppendBridgeLog("AcquireRenderWindow failed: missing UIView");
		return std::nullopt;
	}

	__block CGRect bounds = CGRectZero;
	__block CGFloat scale = UIScreen.mainScreen.scale;
	__block CGFloat refresh_rate = UIScreen.mainScreen.maximumFramesPerSecond;
	if ([NSThread isMainThread])
	{
		bounds = view.bounds;
		scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
		refresh_rate = view.window.screen.maximumFramesPerSecond ?: UIScreen.mainScreen.maximumFramesPerSecond;
	}
	else
	{
		dispatch_sync(dispatch_get_main_queue(), ^{
			bounds = view.bounds;
			scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
			refresh_rate = view.window.screen.maximumFramesPerSecond ?: UIScreen.mainScreen.maximumFramesPerSecond;
		});
	}

	WindowInfo info;
	info.type = WindowInfo::Type::MacOS;
	info.window_handle = (__bridge void*)view;
	info.surface_width = static_cast<u32>(std::max<CGFloat>(1, bounds.size.width * scale));
	info.surface_height = static_cast<u32>(std::max<CGFloat>(1, bounds.size.height * scale));
	info.surface_scale = static_cast<float>(scale);
	info.surface_refresh_rate = static_cast<float>(refresh_rate);
	AppendBridgeLog("AcquireRenderWindow view=" + std::to_string(reinterpret_cast<uintptr_t>((__bridge void*)view)) +
		" bounds=" + std::to_string(static_cast<int>(bounds.size.width)) + "x" +
		std::to_string(static_cast<int>(bounds.size.height)) +
		" surface=" + std::to_string(info.surface_width) + "x" + std::to_string(info.surface_height) +
		" scale=" + std::to_string(info.surface_scale) +
		" refresh=" + std::to_string(info.surface_refresh_rate));
	return info;
}

static void ConfigureDefaultSettings(INISettingsInterface& settings)
{
	VMManager::SetDefaultSettings(settings, true, true, true, true, true);
	settings.SetStringValue("Folders", "Bios", "BIOS");
	settings.SetStringValue("Folders", "Snapshots", "Screenshots");
	settings.SetStringValue("Folders", "Savestates", "States");
	settings.SetStringValue("Folders", "MemoryCards", "Memcards");
	settings.SetStringValue("Folders", "Logs", "Logs");
	settings.SetStringValue("Folders", "Cheats", "Cheats");
	settings.SetStringValue("Folders", "Patches", "Patches");
	settings.SetStringValue("Folders", "UserResources", "Resources");
	settings.SetStringValue("Folders", "Cache", "Cache");
	settings.SetStringValue("Folders", "Textures", "Textures");
	settings.SetStringValue("Folders", "InputProfiles", "InputProfiles");
	settings.SetStringValue("Folders", "Videos", "Videos");
	settings.SetStringValue("EmuCore/GS", "Renderer", "Metal");
	settings.SetFloatValue("EmuCore/GS", "upscale_multiplier", 1.0f);
	settings.SetBoolValue("EmuCore/GS", "FrameLimitEnable", true);
	settings.SetIntValue("EmuCore/GS", "VsyncEnable", 0);
	settings.SetBoolValue("InputSources", "SDL", true);
	settings.SetBoolValue("InputSources", "XInput", false);
	settings.SetStringValue("SPU2/Output", "Backend", "SDL");
	settings.SetIntValue("SPU2/Output", "OutputVolume", 100);
	settings.SetBoolValue("SPU2/Output", "OutputMuted", false);
	settings.SetBoolValue("Logging", "EnableSystemConsole", true);
	settings.SetBoolValue("Logging", "EnableTimestamps", true);
	settings.SetBoolValue("Logging", "EnableFileLogging", true);
	settings.SetBoolValue("Logging", "EnableVerbose", true);
	settings.SetBoolValue("UI", "EnableFullscreenUI", false);
	settings.SetBoolValue("Achievements", "Enabled", false);
}

static void ApplyAmethystUserSettings()
{
	if (!s_settings_interface)
		return;

	const int aspect_ratio = std::clamp(UserInt(@"AMPS2AspectRatio", static_cast<int>(AspectRatioType::RAuto4_3_3_2)), 0,
		static_cast<int>(AspectRatioType::MaxCount) - 1);
	const float upscale = static_cast<float>(std::clamp(UserInt(@"AMPS2UpscaleMultiplier", 1), 1, 8));
	const int ee_cycle_rate = std::clamp(UserInt(@"AMPS2EECycleRate", 0), -3, 3);
	const int ee_cycle_skip = std::clamp(UserInt(@"AMPS2EECycleSkip", 0), 0, 3);
	const GSRendererType renderer = SelectedGSRenderer();
	const CPUProfile cpu_profile = SelectedCPUProfile(renderer);
	const AudioBackend audio_backend = SelectedAudioBackend();
	const bool framebuffer_fetch = EnvBool("AM_PS2_FRAMEBUFFER_FETCH", UserBool(@"AMPS2FramebufferFetch", true));
	const bool vertex_shader_expand = EnvBool("AM_PS2_VERTEX_SHADER_EXPAND", UserBool(@"AMPS2VertexShaderExpand", true));
	const bool wait_loop = cpu_profile.prefer_accuracy_speedhacks ? false :
		EnvBool("AM_PS2_WAIT_LOOP", UserBool(@"AMPS2WaitLoop", true));
	const bool intc_stat = cpu_profile.prefer_accuracy_speedhacks ? false :
		EnvBool("AM_PS2_INTC_STAT", UserBool(@"AMPS2IntcStat", true));
	const bool vu_flag_hack = cpu_profile.prefer_accuracy_speedhacks ? false :
		EnvBool("AM_PS2_MVU_FLAG", EnvBool("AM_PS2_VU_FLAG_HACK", UserBool(@"AMPS2MVUFlag", true)));
	const bool instant_vu1 = cpu_profile.prefer_accuracy_speedhacks ? false :
		EnvBool("AM_PS2_INSTANT_VU1", UserBool(@"AMPS2InstantVU1", true));
	const bool has_increased_memory = HasBooleanEntitlement(@"com.apple.developer.kernel.increased-memory-limit");
	const bool has_extended_va = HasBooleanEntitlement(@"com.apple.developer.kernel.extended-virtual-addressing");

	s_settings_interface->SetBoolValue("EmuCore", "EnableFastBoot", UserBool(@"AMPS2FastBoot", true));
	s_settings_interface->SetBoolValue("EmuCore", "EnablePatches", UserBool(@"AMPS2EnablePatches", true));
	s_settings_interface->SetBoolValue("EmuCore", "EnableCheats", UserBool(@"AMPS2EnableCheats", false));
	s_settings_interface->SetBoolValue("EmuCore", "EnableWideScreenPatches", UserBool(@"AMPS2WidescreenPatches", false));
	s_settings_interface->SetBoolValue("EmuCore", "EnableNoInterlacingPatches", UserBool(@"AMPS2NoInterlacingPatches", false));
	s_settings_interface->SetBoolValue("EmuCore", "HostFs", UserBool(@"AMPS2HostFS", false));
	s_settings_interface->SetBoolValue("EmuCore", "McdFolderAutoManage", true);
	s_settings_interface->SetBoolValue("MemoryCards", "Slot1_Enable", UserBool(@"AMPS2Memcard1Enabled", true));
	s_settings_interface->SetBoolValue("MemoryCards", "Slot2_Enable", UserBool(@"AMPS2Memcard2Enabled", true));
	s_settings_interface->SetStringValue("MemoryCards", "Slot1_Filename", "Mcd001.ps2");
	s_settings_interface->SetStringValue("MemoryCards", "Slot2_Filename", "Mcd002.ps2");

	s_settings_interface->SetIntValue("EmuCore/CPU", "CoreType", cpu_profile.core_type);
	s_settings_interface->SetBoolValue("EmuCore/CPU", "UseArm64Dynarec", cpu_profile.use_arm64_dynarec);
	s_settings_interface->SetIntValue("EmuCore/GS", "Renderer", static_cast<int>(renderer));
	s_settings_interface->SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", cpu_profile.enable_ee_recompiler);
	s_settings_interface->SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", cpu_profile.enable_iop_recompiler);
	s_settings_interface->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", cpu_profile.enable_vu0_recompiler);
	s_settings_interface->SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", cpu_profile.enable_vu1_recompiler);
	s_settings_interface->SetBoolValue("EmuCore/CPU/Recompiler", "EnableFastmem", has_extended_va && cpu_profile.enable_ee_recompiler);
	s_settings_interface->SetStringValue("EmuCore/GS", "AspectRatio", AspectRatioNameForIndex(aspect_ratio));
	s_settings_interface->SetFloatValue("EmuCore/GS", "upscale_multiplier", upscale);
	s_settings_interface->SetBoolValue("EmuCore/GS", "VsyncEnable", UserBool(@"AMPS2VSync", false));
	s_settings_interface->SetBoolValue("EmuCore/GS", "fxaa", UserBool(@"AMPS2FXAA", false));
	s_settings_interface->SetBoolValue("EmuCore/GS", "IntegerScaling", UserBool(@"AMPS2IntegerScaling", false));
	s_settings_interface->SetIntValue("EmuCore/GS", "filter", std::clamp(UserInt(@"AMPS2TextureFiltering", 2), 0, 3));
	s_settings_interface->SetIntValue("EmuCore/GS", "deinterlace_mode", std::clamp(UserInt(@"AMPS2InterlaceMode", 0), 0, 9));
	s_settings_interface->SetIntValue("EmuCore/GS", "accurate_blending_unit", std::clamp(UserInt(@"AMPS2AccurateBlending", 3), 0, 5));
	s_settings_interface->SetIntValue("EmuCore/GS", "MaxAnisotropy", std::clamp(UserInt(@"AMPS2Anisotropy", 0), 0, 16));
	s_settings_interface->SetIntValue("EmuCore/GS", "dithering_ps2", std::clamp(UserInt(@"AMPS2Dithering", 2), 0, 3));
	s_settings_interface->SetIntValue("EmuCore/GS", "linear_present_mode", std::clamp(UserInt(@"AMPS2BilinearPresent", 1), 0, 2));
	s_settings_interface->SetIntValue("EmuCore/GS", "texture_preloading", std::clamp(UserInt(@"AMPS2TexturePreloading", 2), 0, 2));
	s_settings_interface->SetBoolValue("EmuCore/GS", "hw_mipmap", UserBool(@"AMPS2HWMipmap", true));
	s_settings_interface->SetBoolValue("EmuCore/GS", "DisableFramebufferFetch", !framebuffer_fetch);
	s_settings_interface->SetBoolValue("EmuCore/GS", "DisableVertexShaderExpand", !vertex_shader_expand);
	s_settings_interface->SetBoolValue("EmuCore/GS", "autoflush_sw", UserBool(@"AMPS2AutoFlushSW", false));
	s_settings_interface->SetIntValue("EmuCore/GS", "UserHacks_AutoFlushLevel", std::clamp(UserInt(@"AMPS2AutoFlushHW", 0), 0, 2));
	s_settings_interface->SetFloatValue("Framerate", "NominalScalar", UserBool(@"AMPS2FrameLimit", true) ? 1.0f : 10.0f);
	s_settings_interface->SetBoolValue("EmuCore/GS", "OsdShowFPS", UserBool(@"AMPS2OSDFPS", true));
	s_settings_interface->SetBoolValue("EmuCore/GS", "OsdShowSpeed", UserBool(@"AMPS2OSDSpeed", true));
	s_settings_interface->SetBoolValue("EmuCore/GS", "OsdShowResolution", UserBool(@"AMPS2OSDResolution", true));
	s_settings_interface->SetBoolValue("EmuCore/GS", "OsdShowGSStats", UserBool(@"AMPS2OSDGSStats", false));
	s_settings_interface->SetBoolValue("EmuCore/GS", "OsdShowInputs", UserBool(@"AMPS2OSDInputs", false));
	s_settings_interface->SetIntValue("EmuCore/Speedhacks", "EECycleRate", ee_cycle_rate);
	s_settings_interface->SetIntValue("EmuCore/Speedhacks", "EECycleSkip", ee_cycle_skip);
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "fastCDVD", UserBool(@"AMPS2FastCDVD", false));
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "WaitLoop", wait_loop);
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "IntcStat", intc_stat);
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vuFlagHack", vu_flag_hack);
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vu1Instant", instant_vu1);
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vuThread", UserBool(@"AMPS2VUThread", false));
	s_settings_interface->SetBoolValue("Pad1", "Vibration", UserBool(@"AMPS2ControllerVibration", true));
	s_settings_interface->SetStringValue("SPU2/Output", "Backend", AudioBackendName(audio_backend));
	s_settings_interface->SetIntValue("SPU2/Output", "OutputVolume", std::clamp(UserInt(@"AMPS2AudioVolume", 100), 0, 200));
	s_settings_interface->SetBoolValue("SPU2/Output", "OutputMuted", !UserBool(@"AMPS2AudioEnabled", true));

	EmuConfig.EnableFastBoot = UserBool(@"AMPS2FastBoot", true);
	EmuConfig.EnablePatches = UserBool(@"AMPS2EnablePatches", true);
	EmuConfig.EnableCheats = UserBool(@"AMPS2EnableCheats", false);
	EmuConfig.EnableWideScreenPatches = UserBool(@"AMPS2WidescreenPatches", false);
	EmuConfig.EnableNoInterlacingPatches = UserBool(@"AMPS2NoInterlacingPatches", false);
	EmuConfig.HostFs = UserBool(@"AMPS2HostFS", false);
	EmuConfig.McdFolderAutoManage = true;
	EmuConfig.Mcd[0].Enabled = UserBool(@"AMPS2Memcard1Enabled", true);
	EmuConfig.Mcd[1].Enabled = UserBool(@"AMPS2Memcard2Enabled", true);
	EmuConfig.Mcd[0].Filename = "Mcd001.ps2";
	EmuConfig.Mcd[1].Filename = "Mcd002.ps2";
	EmuConfig.Cpu.CoreType = cpu_profile.core_type;
#ifdef PCSX2_ARM64_DYNAREC
	EmuConfig.Cpu.UseArm64Dynarec = cpu_profile.use_arm64_dynarec;
#endif
	EmuConfig.Cpu.Recompiler.EnableEE = cpu_profile.enable_ee_recompiler;
	EmuConfig.Cpu.Recompiler.EnableIOP = cpu_profile.enable_iop_recompiler;
	EmuConfig.Cpu.Recompiler.EnableVU0 = cpu_profile.enable_vu0_recompiler;
	EmuConfig.Cpu.Recompiler.EnableVU1 = cpu_profile.enable_vu1_recompiler;
	EmuConfig.Cpu.Recompiler.EnableFastmem = has_extended_va && cpu_profile.enable_ee_recompiler;
	EmuConfig.GS.Renderer = renderer;
	EmuConfig.GS.AspectRatio = static_cast<AspectRatioType>(aspect_ratio);
	EmuConfig.CurrentAspectRatio = static_cast<AspectRatioType>(aspect_ratio);
	EmuConfig.GS.UpscaleMultiplier = upscale;
	EmuConfig.GS.VsyncEnable = UserBool(@"AMPS2VSync", false);
	EmuConfig.GS.FXAA = UserBool(@"AMPS2FXAA", false);
	EmuConfig.GS.IntegerScaling = UserBool(@"AMPS2IntegerScaling", false);
	EmuConfig.GS.TextureFiltering = static_cast<BiFiltering>(std::clamp(UserInt(@"AMPS2TextureFiltering", 2), 0, 3));
	EmuConfig.GS.InterlaceMode = static_cast<GSInterlaceMode>(std::clamp(UserInt(@"AMPS2InterlaceMode", 0), 0, 9));
	EmuConfig.GS.AccurateBlendingUnit = static_cast<AccBlendLevel>(std::clamp(UserInt(@"AMPS2AccurateBlending", 3), 0, 5));
	EmuConfig.GS.MaxAnisotropy = std::clamp(UserInt(@"AMPS2Anisotropy", 0), 0, 16);
	EmuConfig.GS.Dithering = std::clamp(UserInt(@"AMPS2Dithering", 2), 0, 3);
	EmuConfig.GS.LinearPresent = static_cast<GSPostBilinearMode>(std::clamp(UserInt(@"AMPS2BilinearPresent", 1), 0, 2));
	EmuConfig.GS.TexturePreloading = static_cast<TexturePreloadingLevel>(std::clamp(UserInt(@"AMPS2TexturePreloading", 2), 0, 2));
	EmuConfig.GS.HWMipmap = UserBool(@"AMPS2HWMipmap", true);
	EmuConfig.GS.DisableFramebufferFetch = !framebuffer_fetch;
	EmuConfig.GS.DisableVertexShaderExpand = !vertex_shader_expand;
	EmuConfig.GS.AutoFlushSW = UserBool(@"AMPS2AutoFlushSW", false);
	EmuConfig.GS.UserHacks_AutoFlush = static_cast<GSHWAutoFlushLevel>(std::clamp(UserInt(@"AMPS2AutoFlushHW", 0), 0, 2));
	EmuConfig.EmulationSpeed.NominalScalar = UserBool(@"AMPS2FrameLimit", true) ? 1.0f : 10.0f;
	EmuConfig.GS.OsdShowFPS = UserBool(@"AMPS2OSDFPS", true);
	EmuConfig.GS.OsdShowSpeed = UserBool(@"AMPS2OSDSpeed", true);
	EmuConfig.GS.OsdShowResolution = UserBool(@"AMPS2OSDResolution", true);
	EmuConfig.GS.OsdShowGSStats = UserBool(@"AMPS2OSDGSStats", false);
	EmuConfig.GS.OsdShowInputs = UserBool(@"AMPS2OSDInputs", false);
	EmuConfig.Speedhacks.EECycleRate = ee_cycle_rate;
	EmuConfig.Speedhacks.EECycleSkip = ee_cycle_skip;
	EmuConfig.Speedhacks.fastCDVD = UserBool(@"AMPS2FastCDVD", false);
	EmuConfig.Speedhacks.WaitLoop = wait_loop;
	EmuConfig.Speedhacks.IntcStat = intc_stat;
	EmuConfig.Speedhacks.vuFlagHack = vu_flag_hack;
	EmuConfig.Speedhacks.vu1Instant = instant_vu1;
	EmuConfig.Speedhacks.vuThread = UserBool(@"AMPS2VUThread", false);
	EmuConfig.SPU2.Backend = audio_backend;
	EmuConfig.SPU2.OutputVolume = std::clamp(UserInt(@"AMPS2AudioVolume", 100), 0, 200);
	EmuConfig.SPU2.OutputMuted = !UserBool(@"AMPS2AudioEnabled", true);
	EmuConfig.SPU2.StreamParameters.buffer_ms = 80;
	EmuConfig.SPU2.StreamParameters.output_latency_ms = 40;
	EmuConfig.SPU2.StreamParameters.minimal_output_latency = false;
	GSConfig = EmuConfig.GS;
	GSConfig.Renderer = renderer;
	GSConfig.UpscaleMultiplier = upscale;
	AppendBridgeLog("CPU core configured: CoreType=" + std::to_string(EmuConfig.Cpu.CoreType) +
		" eeRec=" + std::to_string(EmuConfig.Cpu.Recompiler.EnableEE) +
		" iopRec=" + std::to_string(EmuConfig.Cpu.Recompiler.EnableIOP) +
		" vu0Rec=" + std::to_string(EmuConfig.Cpu.Recompiler.EnableVU0) +
		" vu1Rec=" + std::to_string(EmuConfig.Cpu.Recompiler.EnableVU1) +
			" fastBoot=" + std::to_string(EmuConfig.EnableFastBoot) +
			" patches=" + std::to_string(EmuConfig.EnablePatches) +
			" waitLoop=" + std::to_string(EmuConfig.Speedhacks.WaitLoop) +
			" intcStat=" + std::to_string(EmuConfig.Speedhacks.IntcStat) +
			" vuFlagHack=" + std::to_string(EmuConfig.Speedhacks.vuFlagHack) +
			" instantVU1=" + std::to_string(EmuConfig.Speedhacks.vu1Instant) +
			" fastmem=" + std::to_string(EmuConfig.Cpu.Recompiler.EnableFastmem) +
			" increasedMemory=" + std::to_string(has_increased_memory) +
			" extendedVA=" + std::to_string(has_extended_va) +
			" cpuBackend=" + cpu_profile.name +
			" renderer=" + RendererName(renderer) +
			" upscale=" + std::to_string(upscale) +
			" accurateBlending=" + std::to_string(static_cast<int>(EmuConfig.GS.AccurateBlendingUnit)) +
			" framebufferFetch=" + std::to_string(!EmuConfig.GS.DisableFramebufferFetch) +
			" vertexShaderExpand=" + std::to_string(!EmuConfig.GS.DisableVertexShaderExpand) +
			" audioBackend=" + AudioBackendName(audio_backend));
}

static void StartDiagnosticsThread()
{
	StopDiagnosticsThread();
	s_diagnostics_stop = false;
	const bool detailed_diag = EnvBool("AM_PS2_STATE_DIAG");
	s_diagnostics_thread = std::thread([detailed_diag] {
		u64 last_perf_frame = 0;
		u32 last_pc = 0;
		u64 last_cycle = 0;
		bool dumped_stuck_state = false;
		for (int tick = 1; !s_diagnostics_stop; tick++)
		{
			std::this_thread::sleep_for(std::chrono::seconds(2));
			if (s_diagnostics_stop)
				break;

			const VMState state = VMManager::GetState();
			const u64 perf_frame = PerformanceMetrics::GetFrameNumber();
			const u64 gs_frame = g_perfmon.GetFrame();
			const u32 pc = cpuRegs.pc;
			const u64 cycle = cpuRegs.cycle;
			const bool booted_elf = VMManager::Internal::HasBootedELF();
			const bool pc_stuck = (pc == last_pc && cycle == last_cycle && perf_frame == last_perf_frame);
			AppendBridgeLog("Diag tick=" + std::to_string(tick) +
				" state=" + std::to_string(static_cast<int>(state)) +
				" running=" + std::to_string(s_running.load()) +
				" bootedELF=" + std::to_string(booted_elf) +
				" fastBooting=" + std::to_string(VMManager::Internal::IsFastBootInProgress()) +
				" perfFrame=" + std::to_string(perf_frame) +
				" gsFrame=" + std::to_string(gs_frame) +
				" pc=0x" + Hex32(pc) +
					" cycle=" + std::to_string(cycle) +
					" eeStage=" + std::to_string(g_amethyst_ee_event_stage.load(std::memory_order_relaxed)) +
					" jitMarker=0x" + Hex32(g_amethyst_jit_marker) +
					" jitDispRax=0x" + Hex64(g_amps2_jit_dispatch_rax) +
					" eeEventActive=" + std::to_string(eeEventTestIsActive) +
					" interrupt=0x" + Hex32(cpuRegs.interrupt) +
				" dmastall=0x" + Hex32(cpuRegs.dmastall) +
				" dmacStat=0x" + Hex16(static_cast<u32>(psHu16(0xe010))) +
				" dmacMask=0x" + Hex16(static_cast<u32>(psHu16(0xe012))) +
				" stuck=" + std::to_string(pc_stuck));
			if (detailed_diag)
			{
				task_vm_info_data_t vminfo{};
				mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
				if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vminfo), &cnt) == KERN_SUCCESS)
				{
					AppendBridgeLog("Diag mem tick=" + std::to_string(tick) +
						" phys_footprint_mb=" + std::to_string(vminfo.phys_footprint / (1024 * 1024)) +
						" resident_mb=" + std::to_string(vminfo.resident_size / (1024 * 1024)) +
						" internal_mb=" + std::to_string(vminfo.internal / (1024 * 1024)) +
						" compressed_mb=" + std::to_string(vminfo.compressed / (1024 * 1024)) +
						" virtual_mb=" + std::to_string(vminfo.virtual_size / (1024 * 1024)) +
						" available_mb=" + std::to_string(static_cast<uint64_t>(os_proc_available_memory()) / (1024 * 1024)));
				}
			}
			if (detailed_diag)
			{
			AppendBridgeLog("Diag vsync tick=" + std::to_string(tick) +
				" g_FrameCount=" + std::to_string(g_FrameCount) +
				" vsyncMode=" + std::to_string(static_cast<int>(vsyncCounter.Mode)) +
				" vsyncStart=" + std::to_string(vsyncCounter.startCycle) +
				" vsyncDelta=" + std::to_string(vsyncCounter.deltaCycles) +
				" nextStartCounter=" + std::to_string(nextStartCounter) +
				" nextDeltaCounter=" + std::to_string(nextDeltaCounter) +
				" nextEventCycle=" + std::to_string(cpuRegs.nextEventCycle));
			AppendBridgeLog("Diag io tick=" + std::to_string(tick) +
				" iopPc=0x" + Hex32(psxRegs.pc) +
				" iopCycle=" + std::to_string(psxRegs.cycle) +
				" iopNext=" + std::to_string(psxRegs.iopNextEventCycle) +
				" iopCycleEE=" + std::to_string(psxRegs.iopCycleEE) +
				" EEsCycle=" + std::to_string(EEsCycle) +
				" iopEventAction=" + std::to_string(iopEventAction) +
				" psxInt=0x" + Hex32(psxRegs.interrupt) +
				" cdvdReadPending=" + std::to_string((psxRegs.interrupt & (1 << IopEvt_CdvdRead)) != 0) +
				" cdvdReadyPending=" + std::to_string((psxRegs.interrupt & (1 << IopEvt_CdvdSectorReady)) != 0) +
				" cdvdReadRemain=" + std::to_string(psxRemainingCycles(IopEvt_CdvdRead)) +
				" cdvdReadyRemain=" + std::to_string(psxRemainingCycles(IopEvt_CdvdSectorReady)) +
				" intcStat=0x" + Hex32(psHu32(INTC_STAT)) +
				" intcMask=0x" + Hex32(psHu32(INTC_MASK)) +
				" eeIrqCnt[gs,sbus,vbs,vbe,vif0,vif1,gif,tim0,tim1,tim2,tim3]=" +
					std::to_string(g_amps2_ee_intc_count[0]) + "," +
					std::to_string(g_amps2_ee_intc_count[1]) + "," +
					std::to_string(g_amps2_ee_intc_count[2]) + "," +
					std::to_string(g_amps2_ee_intc_count[3]) + "," +
					std::to_string(g_amps2_ee_intc_count[4]) + "," +
					std::to_string(g_amps2_ee_intc_count[5]) + "," +
					std::to_string(g_amps2_ee_intc_count[6]) + "," +
					std::to_string(g_amps2_ee_intc_count[9]) + "," +
					std::to_string(g_amps2_ee_intc_count[10]) + "," +
					std::to_string(g_amps2_ee_intc_count[11]) + "," +
					std::to_string(g_amps2_ee_intc_count[12]) +
				" dmacCtrl=0x" + Hex32(psHu32(DMAC_CTRL)) +
				" iopDmaPcr=0x" + Hex32(HW_DMA_PCR) +
				" iopDmaIcr=0x" + Hex32(HW_DMA_ICR) +
				" sbus[f200=0x" + Hex32(psHu32(SBUS_F200)) +
				" f210=0x" + Hex32(psHu32(SBUS_F210)) +
				" f220=0x" + Hex32(psHu32(SBUS_F220)) +
				" f230=0x" + Hex32(psHu32(SBUS_F230)) +
				" f240=0x" + Hex32(psHu32(SBUS_F240)) +
				"]" +
				" sifDma[s0=" + std::to_string(g_amps2_sif0_dma_count) +
				" s0iop=" + std::to_string(g_amps2_sif0_iop_xfer) +
				" s0ee=" + std::to_string(g_amps2_sif0_ee_xfer) +
				" s0EndEE=" + std::to_string(g_amps2_sif0_endee) +
				" s0EndIOP=" + std::to_string(g_amps2_sif0_endiop) +
				" s0Tag=" + std::to_string(g_amps2_sif0_eetag) +
				" s0TagEnd=" + std::to_string(g_amps2_sif0_eetag_end) +
				" s0Irq=" + std::to_string(g_amps2_sif0_eeirq) +
				" s1=" + std::to_string(g_amps2_sif1_dma_count) +
				"]" +
				" sif0[chcr=0x" + Hex32(psHu32(SIF0_CHCR)) +
				" madr=0x" + Hex32(psHu32(SIF0_MADR)) +
				" qwc=0x" + Hex32(psHu32(SIF0_QWC)) +
				"] sif1[chcr=0x" + Hex32(psHu32(SIF1_CHCR)) +
				" madr=0x" + Hex32(psHu32(SIF1_MADR)) +
				" qwc=0x" + Hex32(psHu32(SIF1_QWC)) +
				" tadr=0x" + Hex32(psHu32(SIF1_TADR)) +
				"] cdvd[sector=" + std::to_string(cdvd.CurrentSector) +
				" seek=" + std::to_string(cdvd.SeekToSector) +
				" left=" + std::to_string(cdvd.SectorCnt) +
				" buffered=" + std::to_string(cdvd.nextSectorsBuffered) +
				" readErr=" + std::to_string(cdvd.ReadErr) +
				" readTime=" + std::to_string(cdvd.ReadTime) +
				" reading=" + std::to_string(cdvd.Reading) +
				" waitingDma=" + std::to_string(cdvd.WaitingDMA) +
				" seekCompleted=" + std::to_string(cdvd.SeekCompleted) +
				" ready=0x" + Hex32(cdvd.Ready) +
				" status=0x" + Hex32(cdvd.Status) +
				" intr=0x" + Hex32(cdvd.IntrStat) +
				"] iopDma3[chcr=0x" + Hex32(HW_DMA3_CHCR) +
				" madr=0x" + Hex32(HW_DMA3_MADR) +
				" bcr=0x" + Hex32(HW_DMA3_BCR) +
				"]");
			AppendBridgeLog("Diag vu-gif tick=" + std::to_string(tick) +
				" vpuStat=0x" + Hex32(VU0.VI[REG_VPU_STAT].UL) +
				" vu1Cycle=" + std::to_string(VU1.cycle) +
				" vu1TPC=0x" + Hex32(VU1.VI[REG_TPC].UL) +
				" vu1NextBlock=" + std::to_string(VU1.nextBlockCycles) +
				" vu1Xgkick[en=" + std::to_string(VU1.xgkickenable) +
				" addr=0x" + Hex32(VU1.xgkickaddr) +
				" remain=" + std::to_string(VU1.xgkicksizeremaining) +
				" count=" + std::to_string(VU1.xgkickcyclecount) +
				" end=" + std::to_string(VU1.xgkickendpacket) +
				"] vif1[stat=0x" + Hex32(vif1Regs.stat._u32) +
				" VEW=" + std::to_string(vif1Regs.stat.VEW) +
				" VGW=" + std::to_string(vif1Regs.stat.VGW) +
				" VPS=" + std::to_string(vif1Regs.stat.VPS) +
				" code=0x" + Hex32(vif1Regs.code) +
				" cmd=0x" + Hex32(static_cast<u32>(vif1.cmd)) +
				" pass=" + std::to_string(vif1.pass) +
				" tagSize=" + std::to_string(vif1.tag.size) +
				" done=" + std::to_string(vif1.done) +
				" waitforvu=" + std::to_string(vif1.waitforvu) +
				" stalled=" + std::to_string(vif1.vifstalled.enabled) +
				" stallValue=" + std::to_string(vif1.vifstalled.value) +
				" inprogress=0x" + Hex32(static_cast<u32>(vif1.inprogress)) +
				" queued=" + std::to_string(vif1.queued_program) +
				" queuedPc=0x" + Hex32(vif1.queued_pc) +
				"] vif1ch[chcr=0x" + Hex32(vif1ch.chcr._u32) +
				" madr=0x" + Hex32(vif1ch.madr) +
				" qwc=0x" + Hex32(vif1ch.qwc) +
				" tadr=0x" + Hex32(vif1ch.tadr) +
				"] gif[stat=0x" + Hex32(gifRegs.stat._u32) +
				" APATH=" + std::to_string(gifRegs.stat.APATH) +
				" OPH=" + std::to_string(gifRegs.stat.OPH) +
				" PSE=" + std::to_string(gifRegs.ctrl.PSE) +
				" pathMask=" + std::to_string(gifUnit.checkPaths(1, 1, 1)) +
				" p1s=" + std::to_string(static_cast<int>(gifUnit.gifPath[GIF_PATH_1].state)) +
				" p1done=" + std::to_string(gifUnit.gifPath[GIF_PATH_1].isDone()) +
				" p1cur=" + std::to_string(gifUnit.gifPath[GIF_PATH_1].curSize) + "/" + std::to_string(gifUnit.gifPath[GIF_PATH_1].curOffset) +
				" p2s=" + std::to_string(static_cast<int>(gifUnit.gifPath[GIF_PATH_2].state)) +
				" p2done=" + std::to_string(gifUnit.gifPath[GIF_PATH_2].isDone()) +
				" p2cur=" + std::to_string(gifUnit.gifPath[GIF_PATH_2].curSize) + "/" + std::to_string(gifUnit.gifPath[GIF_PATH_2].curOffset) +
				" p3s=" + std::to_string(static_cast<int>(gifUnit.gifPath[GIF_PATH_3].state)) +
				" p3done=" + std::to_string(gifUnit.gifPath[GIF_PATH_3].isDone()) +
				" p3cur=" + std::to_string(gifUnit.gifPath[GIF_PATH_3].curSize) + "/" + std::to_string(gifUnit.gifPath[GIF_PATH_3].curOffset) +
				"] gifch[chcr=0x" + Hex32(gifch.chcr._u32) +
				" madr=0x" + Hex32(gifch.madr) +
				" qwc=0x" + Hex32(gifch.qwc) +
				" tadr=0x" + Hex32(gifch.tadr) +
				"]");
				// Dump 8 IOP instructions around iopPc — helps identify the IOP wait-loop function.
				{
					(void)g_amps2_iop_intc_count;
					const u32 ipc = psxRegs.pc & 0x1FFFFFFC;
					std::string iopdump = "Diag iop-dump pc=0x" + Hex32(psxRegs.pc) + " ra=0x" + Hex32(psxRegs.GPR.n.ra) +
						" sp=0x" + Hex32(psxRegs.GPR.n.sp) + " gp=0x" + Hex32(psxRegs.GPR.n.gp) +
						" v0=0x" + Hex32(psxRegs.GPR.n.v0) + " v1=0x" + Hex32(psxRegs.GPR.n.v1) +
						" t0=0x" + Hex32(psxRegs.GPR.n.t0) + " t1=0x" + Hex32(psxRegs.GPR.n.t1) +
						" s0=0x" + Hex32(psxRegs.GPR.n.s0) + " s1=0x" + Hex32(psxRegs.GPR.n.s1) +
						" cause=0x" + Hex32(psxRegs.CP0.n.Cause) + " sr=0x" + Hex32(psxRegs.CP0.n.Status) +
						" iopISTAT=0x" + Hex32(psxHu32(0x1070)) +
						" iopIMASK=0x" + Hex32(psxHu32(0x1074)) +
						" iopICTRL=0x" + Hex32(psxHu32(0x1078)) +
						" iopIrqCnt[vbs,cdvd,dma,spu2,vbe,tmr3]=" +
							std::to_string(g_amps2_iop_intc_count[0]) + "," +
							std::to_string(g_amps2_iop_intc_count[2]) + "," +
							std::to_string(g_amps2_iop_intc_count[3]) + "," +
							std::to_string(g_amps2_iop_intc_count[9]) + "," +
							std::to_string(g_amps2_iop_intc_count[11]) + "," +
							std::to_string(g_amps2_iop_intc_count[14]) +
						" words=[";
					for (int k = -4; k <= 4; ++k)
					{
						const u32 a = ipc + (k * 4);
						const u32 w = iopMemRead32(a);
						iopdump += Hex32(w);
						if (k != 4) iopdump += ",";
					}
					iopdump += "]";
					AppendBridgeLog(iopdump);
				}
				if (booted_elf && (tick <= 8 || (tick % 10) == 0))
				{
					AppendBridgeLog("Diag sample regs pc=0x" + Hex32(pc) +
						" op=[" + DecodeEEInstruction(pc) + "]" +
						" pc4=[" + DecodeEEInstruction(pc + 4) + "]" +
						" ra=0x" + Hex32(cpuRegs.GPR.n.ra.UL[0]) +
						" raop=[" + DecodeEEInstruction(cpuRegs.GPR.n.ra.UL[0]) + "]" +
						" sp=0x" + Hex32(cpuRegs.GPR.n.sp.UL[0]) +
						" gp=0x" + Hex32(cpuRegs.GPR.n.gp.UL[0]) +
						" a0=0x" + Hex32(cpuRegs.GPR.n.a0.UL[0]) +
					" a1=0x" + Hex32(cpuRegs.GPR.n.a1.UL[0]) +
					" a2=0x" + Hex32(cpuRegs.GPR.n.a2.UL[0]) +
					" a3=0x" + Hex32(cpuRegs.GPR.n.a3.UL[0]) +
					" v0=0x" + Hex32(cpuRegs.GPR.n.v0.UL[0]) +
					" v1=0x" + Hex32(cpuRegs.GPR.n.v1.UL[0]) +
						" t0=0x" + Hex32(cpuRegs.GPR.n.t0.UL[0]) +
						" t1=0x" + Hex32(cpuRegs.GPR.n.t1.UL[0]) +
						" t2=0x" + Hex32(cpuRegs.GPR.n.t2.UL[0]) +
						" t3=0x" + Hex32(cpuRegs.GPR.n.t3.UL[0]) +
						" t4=0x" + Hex32(cpuRegs.GPR.n.t4.UL[0]) +
						" t5=0x" + Hex32(cpuRegs.GPR.n.t5.UL[0]) +
						" s0=0x" + Hex32(cpuRegs.GPR.n.s0.UL[0]) +
						" s1=0x" + Hex32(cpuRegs.GPR.n.s1.UL[0]) +
						" s2=0x" + Hex32(cpuRegs.GPR.n.s2.UL[0]) +
						" s3=0x" + Hex32(cpuRegs.GPR.n.s3.UL[0]) +
						" status=0x" + Hex32(cpuRegs.CP0.n.Status.val) +
						" cause=0x" + Hex32(cpuRegs.CP0.n.Cause) +
						" epc=0x" + Hex32(cpuRegs.CP0.n.EPC) +
						" epcop=[" + DecodeEEInstruction(cpuRegs.CP0.n.EPC) + "]");
				}
				if (booted_elf && pc >= 0x00276370 && pc <= 0x002763bc)
				{
					const u32 gp = cpuRegs.GPR.n.gp.UL[0];
					AppendBridgeLog("Diag wait-loop pc=0x" + Hex32(pc) +
						" gp=0x" + Hex32(gp) +
						" gp[-55e8]=" + ReadEEU32(gp - 0x55e8) +
						" gp[-55e4]=" + ReadEEU32(gp - 0x55e4) +
						" gp[-55f0]=" + ReadEEU8(gp - 0x55f0) +
						" gp[-72c0]=" + ReadEEU32(gp - 0x72c0) +
						" v0=0x" + Hex32(cpuRegs.GPR.n.v0.UL[0]) +
						" v1=0x" + Hex32(cpuRegs.GPR.n.v1.UL[0]) +
						" s0=0x" + Hex32(cpuRegs.GPR.n.s0.UL[0]) +
						" s1=0x" + Hex32(cpuRegs.GPR.n.s1.UL[0]) +
						" s2=0x" + Hex32(cpuRegs.GPR.n.s2.UL[0]) +
						" s3=0x" + Hex32(cpuRegs.GPR.n.s3.UL[0]));
					// Dump EE instructions around the wait-loop PC to identify what's being polled.
					std::string ee_asm = "Diag wait-asm pc=0x" + Hex32(pc) + " disasm=[";
					for (int k = -6; k <= 6; ++k)
					{
						const u32 a = pc + (k * 4);
						ee_asm += Hex32(a) + ":" + DecodeEEInstruction(a);
						if (k != 6) ee_asm += " | ";
					}
					ee_asm += "]";
					AppendBridgeLog(ee_asm);

					// Dump EE thread list — shows which threads exist + their state/wait
					{
						const u32 ee_tl = CurrentBiosInformation.eeThreadListAddr;
						std::string tdump = "Diag ee-threads listAddr=0x" + Hex32(ee_tl) + " [";
						if (ee_tl != 0 && ee_tl != (u32)-1)
						{
							const u32 base = ee_tl & 0x3fffff;
							int count = 0;
							for (int tid = 0; tid < 256; ++tid)
							{
								const u32 a = base + tid * sizeof(EEInternalThread);
								if (a + sizeof(EEInternalThread) > Ps2MemSize::MainRam) break;
								const EEInternalThread* it = reinterpret_cast<const EEInternalThread*>(PSM(a));
								if (!it || it->status == 0) continue;
								if (count) tdump += ",";
								tdump += "t" + std::to_string(tid) +
									":s=" + std::to_string(it->status) +
									":w=" + std::to_string(it->waitType) +
									":sema=" + std::to_string(it->semaId) +
									":entry=0x" + Hex32(it->entry) +
									":prio=" + std::to_string(it->currentPriority);
								if (++count >= 16) { tdump += ",..."; break; }
							}
						}
						else
						{
							tdump += "not-yet-located";
						}
						tdump += "]";
						AppendBridgeLog(tdump);
					}

					// One-shot scan of EE main RAM for `sw rX, -0x72C0(gp)` instruction (opcode pattern 0xAF8X_8D40).
					// Identifies which code is supposed to register the callback at gp[-0x72C0].
					static bool s_scanned_72c0 = false;
					if (!s_scanned_72c0)
					{
						s_scanned_72c0 = true;
						std::string scan = "Diag scan-72c0 sw_rt_-72c0(gp) hits=[";
						int hits = 0;
						const u32 maxRam = Ps2MemSize::MainRam;
						for (u32 a = 0; a + 4 <= maxRam; a += 4)
						{
							const u32 w = *reinterpret_cast<const u32*>(PSM(a));
							if ((w & 0xFFE0FFFF) == 0xAF808D40)
							{
								if (hits) scan += ",";
								scan += "0x" + Hex32(a) + ":" + Hex32(w);
								if (++hits >= 32) { scan += ",..."; break; }
							}
						}
						scan += "] total=" + std::to_string(hits);
						AppendBridgeLog(scan);

						// Disassemble around each hit (32 instructions before, 8 after) to find
						// the enclosing function entry (addiu sp,sp,-N / jr ra) and any callers.
						const u32 hit_addrs[2] = { 0x00277F14, 0x002782D0 };
						for (u32 ha : hit_addrs)
						{
							std::string dis = "Diag scan-72c0 disasm @0x" + Hex32(ha) + " [";
							for (int k = -32; k <= 8; ++k)
							{
								const u32 a = ha + (k * 4);
								dis += Hex32(a) + ":" + DecodeEEInstruction(a);
								if (k != 8) dis += " | ";
							}
							dis += "]";
							AppendBridgeLog(dis);
						}

						// Scan for direct callers of 0x00277F10 — function entry uses jr-ra-with-delay-slot
						// pattern (jr ra ; sw a0,-0x72C0(gp)), so jal target = (0x277F10 >> 2) = 0x9DFC4.
						const u32 jal_target = 0x0C000000u | ((0x00277F10u >> 2) & 0x03FFFFFFu);
						std::string callers = "Diag scan-72c0 callers-of-0x277F10 jal=" + Hex32(jal_target) + " hits=[";
						int chits = 0;
						for (u32 a = 0; a + 4 <= maxRam; a += 4)
						{
							const u32 w = *reinterpret_cast<const u32*>(PSM(a));
							if (w == jal_target)
							{
								if (chits) callers += ",";
								callers += "0x" + Hex32(a);
								if (++chits >= 24) { callers += ",..."; break; }
							}
						}
						callers += "] total=" + std::to_string(chits);
						AppendBridgeLog(callers);

						// Also scan for `lui gp / addiu gp` pairs (gp setup) and any reference to current gp - 0x72C0.
						const u32 gp = cpuRegs.GPR.n.gp.UL[0];
						const u32 target_lo = (gp - 0x72C0) & 0xFFFF;
						const u32 target_hi = ((gp - 0x72C0) >> 16) & 0xFFFF;
						std::string scan2 = "Diag scan-72c0 target=0x" + Hex32(gp - 0x72C0) +
							" hi=0x" + Hex16(target_hi) + " lo=0x" + Hex16(target_lo) + " gp=0x" + Hex32(gp);
						AppendBridgeLog(scan2);
					}
				}
			}
				if (pc_stuck && !dumped_stuck_state)
				{
				dumped_stuck_state = true;
					AppendBridgeLog("Diag stuck regs pc=0x" + Hex32(pc) +
						" op=[" + DecodeEEInstruction(pc) + "]" +
						" pc4=[" + DecodeEEInstruction(pc + 4) + "]" +
						" ra=0x" + Hex32(cpuRegs.GPR.n.ra.UL[0]) +
						" raop=[" + DecodeEEInstruction(cpuRegs.GPR.n.ra.UL[0]) + "]" +
						" sp=0x" + Hex32(cpuRegs.GPR.n.sp.UL[0]) +
						" gp=0x" + Hex32(cpuRegs.GPR.n.gp.UL[0]) +
						" nextEvent=" + std::to_string(cpuRegs.nextEventCycle) +
					" interrupt=0x" + Hex32(cpuRegs.interrupt) +
					" dmastall=0x" + Hex32(cpuRegs.dmastall) +
					" dmacStat=0x" + Hex16(static_cast<u32>(psHu16(0xe010))) +
						" dmacMask=0x" + Hex16(static_cast<u32>(psHu16(0xe012))) +
						" status=0x" + Hex32(cpuRegs.CP0.n.Status.val) +
						" cause=0x" + Hex32(cpuRegs.CP0.n.Cause) +
						" epc=0x" + Hex32(cpuRegs.CP0.n.EPC) +
						" epcop=[" + DecodeEEInstruction(cpuRegs.CP0.n.EPC) + "]");
				}
			last_perf_frame = perf_frame;
			last_pc = pc;
			last_cycle = cycle;
		}
	});
}

static void StopDiagnosticsThread()
{
	s_diagnostics_stop = true;
	if (s_diagnostics_thread.joinable())
		s_diagnostics_thread.join();
}

static void EnsureDefaultMemoryCards()
{
	if (!UserBool(@"AMPS2Memcard1Enabled", true) && !UserBool(@"AMPS2Memcard2Enabled", true))
		return;

	EnsureDirectory(EmuFolders::MemoryCards);
	if (UserBool(@"AMPS2Memcard1Enabled", true) &&
		!FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd001.ps2").c_str()))
		FileMcd_CreateNewCard("Mcd001.ps2", MemoryCardType::File, MemoryCardFileType::PS2_8MB);
	if (UserBool(@"AMPS2Memcard2Enabled", true) &&
		!FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd002.ps2").c_str()))
		FileMcd_CreateNewCard("Mcd002.ps2", MemoryCardType::File, MemoryCardFileType::PS2_8MB);
}

static bool PrepareMemoryCardsAtDataRoot(const std::string& data_root)
{
	if (data_root.empty())
	{
		SetLastError("missing data root");
		return false;
	}

	EmuFolders::AppRoot = data_root;
	EmuFolders::DataRoot = data_root;
	EmuFolders::MemoryCards = Path::Combine(data_root, "Memcards");
	NSLog(@"[ARMSX2] Preparing memory cards at %s", EmuFolders::MemoryCards.c_str());
	EnsureDirectory(EmuFolders::MemoryCards);
	if (!FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd001.ps2").c_str()))
		FileMcd_CreateNewCard("Mcd001.ps2", MemoryCardType::File, MemoryCardFileType::PS2_8MB);
	if (!FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd002.ps2").c_str()))
		FileMcd_CreateNewCard("Mcd002.ps2", MemoryCardType::File, MemoryCardFileType::PS2_8MB);
	const bool ready =
		FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd001.ps2").c_str()) &&
		FileSystem::FileExists(Path::Combine(EmuFolders::MemoryCards, "Mcd002.ps2").c_str());
	if (!ready)
		SetLastError("memory card creation failed");
	else
		SetLastError(std::string());
	return ready;
}

static void ApplyRuntimeSettings(const std::string& bios_path)
{
	if (!s_settings_interface)
		return;

	AppendBridgeLog("ApplyRuntimeSettings begin bios=" + bios_path);
	ApplyAmethystUserSettings();

	if (!bios_path.empty())
	{
		const std::string bios_dir(Path::GetDirectory(bios_path));
		const std::string bios_file(Path::GetFileName(bios_path));
		AppendBridgeLog("BIOS dir=" + bios_dir + " file=" + bios_file);
		s_settings_interface->SetStringValue("Folders", "Bios", bios_dir.c_str());
		s_settings_interface->SetStringValue("Filenames", "BIOS", bios_file.c_str());
	}

	AppendBridgeLog("LoadStartupSettings begin");
	VMManager::Internal::LoadStartupSettings();
	AppendBridgeLog("LoadStartupSettings done");
	ApplyAmethystUserSettings();
	AppendBridgeLog("VMManager::ApplySettings begin");
	VMManager::ApplySettings();
	AppendBridgeLog("VMManager::ApplySettings done");
	GSConfig.Renderer = SelectedGSRenderer();
	if (MTGS::IsOpen())
		MTGS::ApplySettings();
	AppendBridgeLog("ReloadInputSources begin");
	VMManager::ReloadInputSources();
	AppendBridgeLog("ReloadInputBindings begin");
	VMManager::ReloadInputBindings(true);
	s_settings_interface->Save();
	AppendBridgeLog("ApplyRuntimeSettings done");
}

static bool InitializeCore(const std::string& data_root, const std::string& resources_root)
{
	if (data_root.empty())
	{
		SetLastError("missing data root");
		return false;
	}

	s_data_root = data_root;
	s_resources_root = resources_root;
	AppendBridgeLog("Initialize data=" + s_data_root + " resources=" + s_resources_root);
	EnsureDirectory(s_data_root);
	EnsureDirectory(Path::Combine(s_data_root, "Logs"));
	{
		NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		if (documents.length > 0)
		{
			std::string log_dir = std::string(documents.UTF8String) + "/ps2/Logs";
			EnsureDirectory(log_dir);
			// Truncate logs on startup so the host-side test driver doesn't need
			// to spawn ios-deploy multiple times to clear stale logs.
			for (const char* name : {"stderr.log", "heartbeat.log", "armsx2-amethyst.log", "metal.log"})
			{
				(void)truncate((log_dir + "/" + name).c_str(), 0);
			}
			const std::string stderr_path = log_dir + "/stderr.log";
			if (!freopen(stderr_path.c_str(), "a", stderr))
				AppendBridgeLog("Warning: failed to redirect stderr to " + stderr_path);
			else
			{
				setvbuf(stderr, nullptr, _IOLBF, 0);
				AppendBridgeLog("stderr redirected to " + stderr_path);
			}
		}
	}
	const LOGLEVEL core_log_level = EnvBool("AM_PS2_VERBOSE_CORE_LOG") ? LOGLEVEL_INFO : LOGLEVEL_WARNING;
	Log::SetHostOutputLevel(core_log_level, AppendCoreLog);
	AppendBridgeLog("Core host log level=" + std::to_string(static_cast<int>(core_log_level)));

	EmuFolders::AppRoot = s_data_root;
	EmuFolders::DataRoot = s_data_root;
	if (!s_resources_root.empty())
		EmuFolders::Resources = s_resources_root;
	else
		EmuFolders::SetResourcesDirectory();
	EnsureDirectory(Path::Combine(s_data_root, "Logs"));
	VMManager::Internal::SetFileLogPath(Path::Combine(Path::Combine(s_data_root, "Logs"), "emulog.txt"));

	const std::string ini_path = Path::Combine(s_data_root, "PCSX2-Amethyst.ini");
	s_settings_interface = std::make_unique<INISettingsInterface>(ini_path);
	Host::Internal::SetBaseSettingsLayer(s_settings_interface.get());
	s_settings_interface->Load();
		if (s_settings_interface->IsEmpty())
			ConfigureDefaultSettings(*s_settings_interface);

		// Smoke test disabled: writing to a JIT26-prepped page in direct-write mode hangs
		// the process (no MAP_JIT, so pthread_jit_write_protect_np is a no-op). The EE
		// recompiler avoids this because Mmap defers prep on the 45MB buffer. Smoke would
		// require a fresh non-prepped page; not worth the cycle.
		// RunJITSmokeTest();

		// Unconditionally install Mach exception handler so EXC_BAD_INSTRUCTION /
		// EXC_BAD_ACCESS from recompiled blocks land in our logger instead of being
		// silently swallowed.
		AMIOSInstallMachExceptionHandler();

		// Heartbeat thread: writes to a separate file every 250ms. Used to distinguish
		// "whole process suspended/killed" (heartbeat stops) from "emulation thread
		// deadlock" (heartbeat continues while bridge log freezes).
		{
			static std::atomic<bool> s_hb_started{false};
			bool expected = false;
			if (s_hb_started.compare_exchange_strong(expected, true))
			{
				std::string hb_data_root = s_data_root;
				NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
				std::string hb_app_root = docs.length > 0 ? std::string(docs.UTF8String) + "/ps2/Logs" : std::string();
				std::thread([hb_data_root, hb_app_root]() {
					pthread_setname_np("armsx2.heartbeat");
					uint64_t beat = 0;
					while (true)
					{
						auto now = std::chrono::system_clock::now();
						std::time_t tt = std::chrono::system_clock::to_time_t(now);
						struct tm tm_local;
						localtime_r(&tt, &tm_local);
						auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
						char ts[64];
						snprintf(ts, sizeof(ts), "%04d-%02d-%02d %02d:%02d:%02d.%03lld",
							tm_local.tm_year + 1900, tm_local.tm_mon + 1, tm_local.tm_mday,
							tm_local.tm_hour, tm_local.tm_min, tm_local.tm_sec, (long long)ms);
							char line[512];
							task_vm_info_data_t vmi = {};
							mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
							kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt);
							uint64_t footprint_mb = (kr == KERN_SUCCESS) ? (vmi.phys_footprint >> 20) : 0;
							uint64_t limit_mb = (kr == KERN_SUCCESS) ? (vmi.limit_bytes_remaining >> 20) : 0;
							int n = snprintf(line, sizeof(line),
								"%s HB beat=%llu phys=%lluMB remain=%lluMB pc=0x%08X cycle=%llu iopPc=0x%08X jitPc=0x%llx jitRcx=0x%llx jitRax=0x%llx jitCount=%llu marker=0x%08X\n",
								ts, (unsigned long long)beat,
								(unsigned long long)footprint_mb, (unsigned long long)limit_mb,
								cpuRegs.pc, (unsigned long long)cpuRegs.cycle, psxRegs.pc,
								(unsigned long long)g_amps2_jit_dispatch_pc,
								(unsigned long long)g_amps2_jit_dispatch_rcx,
								(unsigned long long)g_amps2_jit_dispatch_rax,
								(unsigned long long)g_amps2_jit_dispatch_count,
								g_amethyst_jit_marker);
						if (!hb_data_root.empty())
						{
							std::ofstream s(hb_data_root + "/Logs/heartbeat.log", std::ios::app);
							if (s) s.write(line, n);
						}
						if (!hb_app_root.empty())
						{
							std::ofstream s(hb_app_root + "/heartbeat.log", std::ios::app);
							if (s) s.write(line, n);
						}
						beat++;
						std::this_thread::sleep_for(std::chrono::milliseconds(250));
					}
				}).detach();
			}
		}
		{
				struct sigaction sa = {};
				sigemptyset(&sa.sa_mask);
				sa.sa_flags = SA_SIGINFO | SA_NODEFER;
				sa.sa_sigaction = [](int sig, siginfo_t* info, void* ctx) {
				ucontext_t* uctx = static_cast<ucontext_t*>(ctx);
				uintptr_t pc = 0, lr = 0, sp = 0, fp = 0;
				uint32_t b0 = 0, b1 = 0, b2 = 0, b3 = 0;
				if (uctx && uctx->uc_mcontext)
				{
					pc = uctx->uc_mcontext->__ss.__pc;
					lr = uctx->uc_mcontext->__ss.__lr;
					sp = uctx->uc_mcontext->__ss.__sp;
					fp = uctx->uc_mcontext->__ss.__fp;
				}
				if (pc >= 0x100000000ull && pc < 0xf00000000000ull)
				{
					const uint32_t* p = reinterpret_cast<const uint32_t*>(pc);
					b0 = p[0]; b1 = p[1]; b2 = p[2]; b3 = p[3];
				}
				char buf[256];
				int n = snprintf(buf, sizeof(buf),
					"AMPS2 FATAL sig=%d code=%d addr=%p pc=%lx lr=%lx sp=%lx fp=%lx bytes=%08x %08x %08x %08x\n",
					sig, info ? info->si_code : 0, info ? info->si_addr : nullptr,
					(unsigned long)pc, (unsigned long)lr, (unsigned long)sp, (unsigned long)fp,
					b0, b1, b2, b3);
					if (n > 0)
					{
						(void)write(STDERR_FILENO, buf, (size_t)n);
					}
					n = snprintf(buf, sizeof(buf),
						"AMPS2 FATAL state pc=0x%08X cycle=%llu iopPc=0x%08X jitPc=0x%llx jitRcx=0x%llx jitRax=0x%llx jitCount=%llu marker=0x%08X\n",
						cpuRegs.pc, (unsigned long long)cpuRegs.cycle, psxRegs.pc,
						(unsigned long long)g_amps2_jit_dispatch_pc,
						(unsigned long long)g_amps2_jit_dispatch_rcx,
						(unsigned long long)g_amps2_jit_dispatch_rax,
						(unsigned long long)g_amps2_jit_dispatch_count,
						g_amethyst_jit_marker);
					if (n > 0) (void)write(STDERR_FILENO, buf, (size_t)n);
				// Dump 8 instructions before PC for context.
				if (pc >= 0x100000000ull && pc < 0xf00000000000ull)
				{
					const uint32_t* p = reinterpret_cast<const uint32_t*>(pc - 32);
					n = snprintf(buf, sizeof(buf),
						"AMPS2 FATAL pre-pc: %08x %08x %08x %08x %08x %08x %08x %08x\n",
						p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
					if (n > 0) (void)write(STDERR_FILENO, buf, (size_t)n);
				}
				// Dump first 4 stack slots near fp (caller chain).
				if (fp && fp >= 0x100000000ull && fp < 0xf00000000000ull)
				{
					const uint64_t* fpp = reinterpret_cast<const uint64_t*>(fp);
					n = snprintf(buf, sizeof(buf),
						"AMPS2 FATAL fp[0..3]: %llx %llx %llx %llx\n",
						(unsigned long long)fpp[0], (unsigned long long)fpp[1],
						(unsigned long long)fpp[2], (unsigned long long)fpp[3]);
					if (n > 0) (void)write(STDERR_FILENO, buf, (size_t)n);
				}
				(void)fsync(STDERR_FILENO);
				signal(sig, SIG_DFL);
				raise(sig);
				};
				sigaction(SIGILL, &sa, nullptr);
				sigaction(SIGTRAP, &sa, nullptr);
				sigaction(SIGABRT, &sa, nullptr);
				// EXC_BREAKPOINT is still omitted from the Mach handler because
				// SideStore JIT26 uses BRK #0xf00d as its debugger-side syscall path.
				// A BSD SIGTRAP handler only runs if no debugger-side handler consumed it.
				// Don't override SIGSEGV/SIGBUS; vtlb fastmem handler owns those.
			}
			{
				static std::atomic<bool> s_exit_hooks_started{false};
				bool expected = false;
				if (s_exit_hooks_started.compare_exchange_strong(expected, true))
				{
					std::set_terminate([] {
						char buf[384];
						int n = snprintf(buf, sizeof(buf),
							"AMPS2 TERMINATE pc=0x%08X cycle=%llu iopPc=0x%08X jitPc=0x%llx jitRax=0x%llx jitCount=%llu marker=0x%08X\n",
							cpuRegs.pc, (unsigned long long)cpuRegs.cycle, psxRegs.pc,
							(unsigned long long)g_amps2_jit_dispatch_pc,
							(unsigned long long)g_amps2_jit_dispatch_rax,
							(unsigned long long)g_amps2_jit_dispatch_count,
							g_amethyst_jit_marker);
						if (n > 0) (void)write(STDERR_FILENO, buf, (size_t)n);
						(void)fsync(STDERR_FILENO);
						std::abort();
					});
					std::atexit([] {
						char buf[384];
						int n = snprintf(buf, sizeof(buf),
							"AMPS2 ATEXIT pc=0x%08X cycle=%llu iopPc=0x%08X jitPc=0x%llx jitRax=0x%llx jitCount=%llu marker=0x%08X\n",
							cpuRegs.pc, (unsigned long long)cpuRegs.cycle, psxRegs.pc,
							(unsigned long long)g_amps2_jit_dispatch_pc,
							(unsigned long long)g_amps2_jit_dispatch_rax,
							(unsigned long long)g_amps2_jit_dispatch_count,
							g_amethyst_jit_marker);
						if (n > 0) (void)write(STDERR_FILENO, buf, (size_t)n);
						(void)fsync(STDERR_FILENO);
					});
				}
			}

		ApplyRuntimeSettings(std::string());
		EmuFolders::LoadConfig(*s_settings_interface);
	EmuFolders::EnsureFoldersExist();
	NSLog(@"[ARMSX2] Folders app=%s data=%s resources=%s memcards=%s logs=%s",
		EmuFolders::AppRoot.c_str(), EmuFolders::DataRoot.c_str(), EmuFolders::Resources.c_str(),
		EmuFolders::MemoryCards.c_str(), EmuFolders::Logs.c_str());
	EnsureDefaultMemoryCards();
	ImGuiManager::SetFontPathAndRange(
		Path::Combine(EmuFolders::Resources, "fonts" FS_OSPATH_SEPARATOR_STR "Roboto-Regular.ttf"), {});

	s_initialized = true;
	SetLastError(std::string());
	return true;
}

static void RunVM(std::string iso_path, std::string bios_path)
{
	t_on_cpu_thread = true;
	s_booting = true;
	s_running = false;
	s_stop_requested = false;
	AppendBridgeLog("RunVM iso=" + iso_path + " bios=" + bios_path);
	AppendBridgeLog("RunVM ApplyRuntimeSettings begin");
	ApplyRuntimeSettings(bios_path);
	AppendBridgeLog("RunVM ApplyRuntimeSettings done");
	AppendBridgeLog("RunVM EnsureDefaultMemoryCards begin");
	EnsureDefaultMemoryCards();
	AppendBridgeLog("RunVM EnsureDefaultMemoryCards done");

	VMBootParameters boot_params;
	boot_params.filename = std::move(iso_path);
	boot_params.source_type = CDVD_SourceType::Iso;

	AppendBridgeLog("CPUThreadInitialize begin");
	if (!VMManager::Internal::CPUThreadInitialize())
	{
		SetLastError("CPUThreadInitialize failed");
		VMManager::Internal::CPUThreadShutdown();
		s_booting = false;
		s_running = false;
		return;
	}
	AppendBridgeLog("CPUThreadInitialize done");

	AppendBridgeLog("VMManager::ApplySettings before initialize begin");
	VMManager::ApplySettings();
	AppendBridgeLog("VMManager::ApplySettings before initialize done");
	GSDumpReplayer::SetIsDumpRunner(false);

	AppendBridgeLog("VMManager::Initialize begin");
	if (!VMManager::Initialize(boot_params))
	{
		SetLastError("VMManager::Initialize failed");
		VMManager::Internal::CPUThreadShutdown();
		s_booting = false;
		s_running = false;
		return;
	}
	AppendBridgeLog("VMManager::Initialize done state=" + std::to_string(static_cast<int>(VMManager::GetState())));

	VMManager::SetState(VMState::Running);
	s_booting = false;
	s_running = true;
	AppendBridgeLog("VM running");
	StartDiagnosticsThread();
	const bool jit_diag = EnvBool("AM_PS2_JIT_DIAG");
	while (!s_stop_requested)
	{
		DrainCPUThreadTasks();
		const VMState state = VMManager::GetState();
		if (state == VMState::Stopping || state == VMState::Shutdown)
			break;
		if (state == VMState::Running)
		{
			if (jit_diag)
				AppendBridgeLog("VMManager::Execute entering pc=0x" + Hex32(cpuRegs.pc));
			VMManager::Execute();
			if (jit_diag)
				AppendBridgeLog("VMManager::Execute returned while state=" + std::to_string(static_cast<int>(VMManager::GetState())) +
					" pc=0x" + Hex32(cpuRegs.pc) +
					" cycle=" + std::to_string(cpuRegs.cycle));
		}
		else
			std::this_thread::sleep_for(std::chrono::milliseconds(250));
	}

	StopDiagnosticsThread();
	VMManager::Shutdown(false);
	VMManager::Internal::CPUThreadShutdown();
	DrainCPUThreadTasks();
	t_on_cpu_thread = false;
	s_booting = false;
	s_running = false;
	AppendBridgeLog("VM stopped");
}

static bool RunVMTaskSync(std::function<bool()> task)
{
	if (!VMManager::HasValidVM())
	{
		SetLastError("VM is not running");
		return false;
	}
	if (t_on_cpu_thread)
		return task();

	struct TaskState
	{
		std::mutex mutex;
		std::condition_variable cv;
		bool done = false;
		bool result = false;
	};
	std::shared_ptr<TaskState> state = std::make_shared<TaskState>();
	EnqueueCPUThreadTask([state, task = std::move(task)] {
		const bool task_result = task();
		{
			std::lock_guard done_lock(state->mutex);
			state->result = task_result;
			state->done = true;
		}
		state->cv.notify_one();
	});

	std::unique_lock done_lock(state->mutex);
	if (!state->cv.wait_for(done_lock, std::chrono::seconds(5), [&] { return state->done; }))
	{
		SetLastError("CPU thread task timed out");
		return false;
	}
	return state->result;
}
} // namespace

AMETHYST_EXPORT int ARMSX2AmethystInitialize(const char* data_root, const char* resources_root)
{
	return InitializeCore(StringFromCString(data_root), StringFromCString(resources_root)) ? 1 : 0;
}

AMETHYST_EXPORT int ARMSX2AmethystStart(UIView* render_view, const char* iso_path, const char* bios_path)
{
	const std::string iso = StringFromCString(iso_path);
	AppendBridgeLog("Start request iso=" + iso +
		" bios=" + StringFromCString(bios_path) +
		" initialized=" + std::to_string(s_initialized.load()) +
		" running=" + std::to_string(s_running.load()));
	if (!s_initialized)
	{
		SetLastError("core is not initialized");
		return 0;
	}
	if (!render_view)
	{
		SetLastError("missing render view");
		return 0;
	}
	if (iso.empty() || !FileSystem::FileExists(iso.c_str()))
	{
		SetLastError("missing PS2 image");
		return 0;
	}
	if (s_booting || s_running)
		return 1;

	if (s_vm_thread.joinable())
		s_vm_thread.join();

	s_render_view = render_view;
	s_vm_thread = std::thread(RunVM, iso, StringFromCString(bios_path));
	return 1;
}

AMETHYST_EXPORT void ARMSX2AmethystStop()
{
	s_stop_requested = true;
	if (VMManager::HasValidVM())
		Host::RunOnCPUThread([] { VMManager::SetState(VMState::Stopping); });
	if (s_vm_thread.joinable())
		s_vm_thread.join();
}

AMETHYST_EXPORT void ARMSX2AmethystPause(int paused)
{
	if (VMManager::HasValidVM())
		Host::RunOnCPUThread([paused] { VMManager::SetPaused(paused != 0); });
}

AMETHYST_EXPORT int ARMSX2AmethystIsRunning()
{
	return (s_running && VMManager::GetState() == VMState::Running) ? 1 : 0;
}

AMETHYST_EXPORT int ARMSX2AmethystSaveState(int slot)
{
	return RunVMTaskSync([slot] { return VMManager::SaveStateToSlot(slot, false); }) ? 1 : 0;
}

AMETHYST_EXPORT int ARMSX2AmethystLoadState(int slot)
{
	return RunVMTaskSync([slot] { return VMManager::LoadStateFromSlot(slot); }) ? 1 : 0;
}

AMETHYST_EXPORT int ARMSX2AmethystPrepareMemoryCards(const char* data_root)
{
	return PrepareMemoryCardsAtDataRoot(StringFromCString(data_root)) ? 1 : 0;
}

AMETHYST_EXPORT void ARMSX2AmethystSetPadButton(int key, int range, int pressed)
{
	PadDualshock2::Inputs pad_key;
	switch (key)
	{
		case 19: pad_key = PadDualshock2::Inputs::PAD_UP; break;
		case 22: pad_key = PadDualshock2::Inputs::PAD_RIGHT; break;
		case 20: pad_key = PadDualshock2::Inputs::PAD_DOWN; break;
		case 21: pad_key = PadDualshock2::Inputs::PAD_LEFT; break;
		case 100: pad_key = PadDualshock2::Inputs::PAD_TRIANGLE; break;
		case 97: pad_key = PadDualshock2::Inputs::PAD_CIRCLE; break;
		case 96: pad_key = PadDualshock2::Inputs::PAD_CROSS; break;
		case 99: pad_key = PadDualshock2::Inputs::PAD_SQUARE; break;
		case 109: pad_key = PadDualshock2::Inputs::PAD_SELECT; break;
		case 108: pad_key = PadDualshock2::Inputs::PAD_START; break;
		case 102: pad_key = PadDualshock2::Inputs::PAD_L1; break;
		case 104: pad_key = PadDualshock2::Inputs::PAD_L2; break;
		case 103: pad_key = PadDualshock2::Inputs::PAD_R1; break;
		case 105: pad_key = PadDualshock2::Inputs::PAD_R2; break;
		case 106: pad_key = PadDualshock2::Inputs::PAD_L3; break;
		case 107: pad_key = PadDualshock2::Inputs::PAD_R3; break;
		case 110: pad_key = PadDualshock2::Inputs::PAD_L_UP; break;
		case 111: pad_key = PadDualshock2::Inputs::PAD_L_RIGHT; break;
		case 112: pad_key = PadDualshock2::Inputs::PAD_L_DOWN; break;
		case 113: pad_key = PadDualshock2::Inputs::PAD_L_LEFT; break;
		case 120: pad_key = PadDualshock2::Inputs::PAD_R_UP; break;
		case 121: pad_key = PadDualshock2::Inputs::PAD_R_RIGHT; break;
		case 122: pad_key = PadDualshock2::Inputs::PAD_R_DOWN; break;
		case 123: pad_key = PadDualshock2::Inputs::PAD_R_LEFT; break;
		default: return;
	}

	float value = 0.0f;
	if (pressed)
		value = range > 0 ? static_cast<float>(std::clamp(range, 0, 255)) / 255.0f : 1.0f;
	Pad::SetControllerState(0, static_cast<u32>(pad_key), value);
	Pad::UpdateMacroButtons();
}

AMETHYST_EXPORT void ARMSX2AmethystResetPad(void)
{
	for (u32 pad = 0; pad < Pad::NUM_CONTROLLER_PORTS; pad++)
	{
		for (u32 key = 0; key < static_cast<u32>(PadDualshock2::Inputs::LENGTH); key++)
			Pad::SetControllerState(pad, key, 0.0f);
	}
	Pad::UpdateMacroButtons();
}

AMETHYST_EXPORT const char* ARMSX2AmethystLastError()
{
	static thread_local std::string last_error;
	std::lock_guard lock(s_bridge_mutex);
	last_error = s_last_error;
	return last_error.c_str();
}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
	return WindowInfoForView(s_render_view);
}

void Host::ReleaseRenderWindow() {}
void Host::BeginPresentFrame()
{
	using Clock = std::chrono::steady_clock;
	static Clock::time_point s_last_present_time;
	static u64 s_last_present_frame = 0;

	const auto now = Clock::now();
	const u64 frame = PerformanceMetrics::GetFrameNumber();
	if (s_last_present_time.time_since_epoch().count() != 0)
	{
		const double delta_ms = static_cast<double>(
			std::chrono::duration_cast<std::chrono::microseconds>(now - s_last_present_time).count()) / 1000.0;
		if (delta_ms > 120.0)
		{
			AppendBridgeLog("Perf present-stall frame=" + std::to_string(frame) +
				" prevFrame=" + std::to_string(s_last_present_frame) +
				" deltaMs=" + std::to_string(delta_ms) +
				" fps=" + std::to_string(PerformanceMetrics::GetFPS()) +
				" internal=" + std::to_string(PerformanceMetrics::GetInternalFPS()) +
				" cpu=" + std::to_string(PerformanceMetrics::GetCPUThreadUsage()) +
				" gs=" + std::to_string(PerformanceMetrics::GetGSThreadUsage()));
		}
	}

	s_last_present_time = now;
	s_last_present_frame = frame;
}
void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
	const std::string& disc_serial, u32 disc_crc, u32 current_crc) {}
void Host::PumpMessagesOnCPUThread()
{
	DrainCPUThreadTasks();
}
void Host::CommitBaseSettingChanges()
{
	auto lock = GetSettingsLock();
	if (s_settings_interface)
		s_settings_interface->Save();
}
void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock) {}
void Host::CheckForSettingsChanges(const Pcsx2Config& old_config) {}
bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui) { return false; }
void Host::SetDefaultUISettings(SettingsInterface& si) {}
std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback() { return nullptr; }
void Host::ReportInfoAsync(const std::string_view title, const std::string_view message)
{
	if (!message.empty())
		AppendBridgeLog("INFO " + std::string(title) + ": " + std::string(message));
}
void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
	SetLastError(std::string(message));
}
bool Host::ConfirmMessage(const std::string_view title, const std::string_view message) { return true; }
void Host::OpenURL(const std::string_view url)
{
	NSString* url_string = [[NSString alloc] initWithBytes:url.data() length:url.size() encoding:NSUTF8StringEncoding];
	NSURL* ns_url = url_string ? [NSURL URLWithString:url_string] : nil;
	if (!ns_url)
		return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[UIApplication.sharedApplication openURL:ns_url options:@{} completionHandler:nil];
	});
}
bool Host::CopyTextToClipboard(const std::string_view text)
{
	NSString* ns_text = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
	if (!ns_text)
		return false;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIPasteboard.generalPasteboard.string = ns_text;
	});
	return true;
}
void Host::BeginTextInput() {}
void Host::EndTextInput() {}
std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
	return WindowInfoForView(s_render_view);
}
void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name) {}
void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier) {}
void Host::SetMouseMode(bool relative_mode, bool hide_cursor) {}
void Host::RequestResizeHostDisplay(s32 width, s32 height) {}
void Host::OnVMStarting() {}
void Host::OnVMStarted() {}
void Host::OnVMDestroyed() {}
void Host::OnVMPaused() {}
void Host::OnVMResumed() {}
void Host::OnPerformanceMetricsUpdated()
{
	using Clock = std::chrono::steady_clock;
	static u64 s_last_logged_frame = 0;
	static Clock::time_point s_last_logged_time;
	const u64 frame = PerformanceMetrics::GetFrameNumber();
	if (frame == 0 || frame - s_last_logged_frame < 120)
		return;

	const auto now = Clock::now();
	const u64 previous_frame = s_last_logged_frame;
	const bool has_previous_time = s_last_logged_time.time_since_epoch().count() != 0;
	const u64 frame_delta = previous_frame == 0 ? 0 : frame - previous_frame;
	const double wall_ms = has_previous_time ?
		static_cast<double>(std::chrono::duration_cast<std::chrono::microseconds>(now - s_last_logged_time).count()) / 1000.0 :
		0.0;
	const double expected_ms = frame_delta > 0 ? (static_cast<double>(frame_delta) * 1000.0 / 60.0) : 0.0;
	const double stall_ms = (wall_ms > expected_ms) ? (wall_ms - expected_ms) : 0.0;

	s_last_logged_frame = frame;
	s_last_logged_time = now;
	if (stall_ms > 250.0)
	{
		AppendBridgeLog("Perf window-stall frame=" + std::to_string(frame) +
			" frameDelta=" + std::to_string(frame_delta) +
			" wallMs=" + std::to_string(wall_ms) +
			" expectedMs=" + std::to_string(expected_ms) +
			" stallMs=" + std::to_string(stall_ms));
	}

	AppendBridgeLog("Perf frame=" + std::to_string(frame) +
		" fps=" + std::to_string(PerformanceMetrics::GetFPS()) +
		" internal=" + std::to_string(PerformanceMetrics::GetInternalFPS()) +
		" speed=" + std::to_string(PerformanceMetrics::GetSpeed()) +
		" cpu=" + std::to_string(PerformanceMetrics::GetCPUThreadUsage()) +
		" gs=" + std::to_string(PerformanceMetrics::GetGSThreadUsage()) +
		" frameDelta=" + std::to_string(frame_delta) +
		" wallMs=" + std::to_string(wall_ms) +
		" stallMs=" + std::to_string(stall_ms));
}
void Host::OnSaveStateLoading(const std::string_view filename) {}
void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful) {}
void Host::OnSaveStateSaved(const std::string_view filename) {}
void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
	if (t_on_cpu_thread || (!s_running && !VMManager::HasValidVM()))
	{
		function();
		return;
	}

	if (!block)
	{
		EnqueueCPUThreadTask(std::move(function));
		return;
	}

	std::mutex done_mutex;
	std::condition_variable done_cv;
	bool done = false;
	EnqueueCPUThreadTask([&] {
		function();
		{
			std::lock_guard done_lock(done_mutex);
			done = true;
		}
		done_cv.notify_one();
	});
	std::unique_lock done_lock(done_mutex);
	done_cv.wait(done_lock, [&] { return done; });
}
void Host::RefreshGameListAsync(bool invalidate_cache) {}
void Host::CancelGameListRefresh() {}
bool Host::IsFullscreen() { return false; }
void Host::SetFullscreen(bool enabled) {}
void Host::OnCaptureStarted(const std::string& filename) {}
void Host::OnCaptureStopped() {}
void Host::RequestExitApplication(bool allow_confirm) {}
void Host::RequestExitBigPicture() {}
void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
	VMManager::SetState(VMState::Stopping);
}
bool Host::InBatchMode() { return false; }
bool Host::LocaleCircleConfirm() { return false; }
bool Host::InNoGUIMode() { return false; }
void Host::OnCoverDownloaderOpenRequested() {}
void Host::OnCreateMemoryCardOpenRequested() {}
bool Host::ShouldPreferHostFileSelector() { return false; }
void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory, FileSelectorCallback callback,
	FileSelectorFilters filters, std::string_view initial_directory)
{
	callback(std::string());
}
void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages) {}
void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason) {}
void Host::OnAchievementsHardcoreModeChanged(bool enabled) {}
void Host::OnAchievementsRefreshed() {}
s32 Host::Internal::GetTranslatedStringImpl(
	const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
	if (msg.size() > tbuf_space)
		return -1;
	if (msg.empty())
		return 0;
	std::memcpy(tbuf, msg.data(), msg.size());
	return static_cast<s32>(msg.size());
}
std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
	std::string ret(msg);
	const std::string count_string = std::to_string(count);
	for (;;)
	{
		const std::string::size_type pos = ret.find("%n");
		if (pos == std::string::npos)
			break;
		ret.replace(pos, 2, count_string);
	}
	return ret;
}

namespace InputManager
{
std::optional<u32> ConvertHostKeyboardStringToCode(const std::string_view str) { return std::nullopt; }
std::optional<std::string> ConvertHostKeyboardCodeToString(u32 code) { return std::nullopt; }
const char* ConvertHostKeyboardCodeToIcon(u32 code) { return nullptr; }
}
