#include "common/FileSystem.h"
#include "common/Path.h"
#include "common/SettingsInterface.h"
#include "common/StringUtil.h"
#include "common/WindowInfo.h"

#include "pcsx2/Achievements.h"
#include "pcsx2/Config.h"
#include "pcsx2/GS.h"
#include "pcsx2/GS/GSPerfMon.h"
#include "pcsx2/Host.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/Patch.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/SIO/Pad/PadDualshock2.h"
#include "pcsx2/SIO/Memcard/MemoryCardFile.h"

#include "GSDumpReplayer.h"
#include "PerformanceMetrics.h"

#include <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace
{
std::unique_ptr<INISettingsInterface> s_settings_interface;
std::mutex s_bridge_mutex;
std::thread s_vm_thread;
std::atomic_bool s_initialized{false};
std::atomic_bool s_running{false};
std::atomic_bool s_stop_requested{false};
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

static bool UserBool(NSString* key, bool default_value)
{
	id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
	return value ? [NSUserDefaults.standardUserDefaults boolForKey:key] : default_value;
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

static void EnsureDirectory(const std::string& path)
{
	if (!path.empty())
		FileSystem::CreateDirectoryPath(path.c_str(), false);
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
		return std::nullopt;

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
	settings.SetFloatValue("EmuCore/GS", "upscale_multiplier", 2.0f);
	settings.SetBoolValue("EmuCore/GS", "FrameLimitEnable", true);
	settings.SetIntValue("EmuCore/GS", "VsyncEnable", 0);
	settings.SetBoolValue("InputSources", "SDL", true);
	settings.SetBoolValue("InputSources", "XInput", false);
	settings.SetStringValue("SPU2/Output", "Backend", "SDL");
	settings.SetIntValue("SPU2/Output", "OutputVolume", 100);
	settings.SetBoolValue("SPU2/Output", "OutputMuted", false);
	settings.SetBoolValue("Logging", "EnableSystemConsole", true);
	settings.SetBoolValue("Logging", "EnableTimestamps", true);
	settings.SetBoolValue("UI", "EnableFullscreenUI", false);
	settings.SetBoolValue("Achievements", "Enabled", false);
}

static void ApplyAmethystUserSettings()
{
	if (!s_settings_interface)
		return;

	const int aspect_ratio = std::clamp(UserInt(@"AMPS2AspectRatio", static_cast<int>(AspectRatioType::RAuto4_3_3_2)), 0,
		static_cast<int>(AspectRatioType::MaxCount) - 1);
	const float upscale = static_cast<float>(std::clamp(UserInt(@"AMPS2UpscaleMultiplier", 2), 1, 8));
	const int ee_cycle_rate = std::clamp(UserInt(@"AMPS2EECycleRate", 0), -3, 3);
	const int ee_cycle_skip = std::clamp(UserInt(@"AMPS2EECycleSkip", 0), 0, 3);

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

	s_settings_interface->SetIntValue("EmuCore/GS", "Renderer", static_cast<int>(GSRendererType::Metal));
	s_settings_interface->SetStringValue("EmuCore/GS", "AspectRatio", AspectRatioNameForIndex(aspect_ratio));
	s_settings_interface->SetFloatValue("EmuCore/GS", "upscale_multiplier", upscale);
	s_settings_interface->SetBoolValue("EmuCore/GS", "VsyncEnable", UserBool(@"AMPS2VSync", false));
	s_settings_interface->SetBoolValue("EmuCore/GS", "fxaa", UserBool(@"AMPS2FXAA", false));
	s_settings_interface->SetBoolValue("EmuCore/GS", "IntegerScaling", UserBool(@"AMPS2IntegerScaling", false));
	s_settings_interface->SetIntValue("EmuCore/GS", "filter", std::clamp(UserInt(@"AMPS2TextureFiltering", 2), 0, 3));
	s_settings_interface->SetIntValue("EmuCore/GS", "deinterlace_mode", std::clamp(UserInt(@"AMPS2InterlaceMode", 0), 0, 9));
	s_settings_interface->SetIntValue("EmuCore/GS", "accurate_blending_unit", std::clamp(UserInt(@"AMPS2AccurateBlending", 1), 0, 5));
	s_settings_interface->SetIntValue("EmuCore/GS", "MaxAnisotropy", std::clamp(UserInt(@"AMPS2Anisotropy", 0), 0, 16));
	s_settings_interface->SetIntValue("EmuCore/GS", "dithering_ps2", std::clamp(UserInt(@"AMPS2Dithering", 2), 0, 3));
	s_settings_interface->SetIntValue("EmuCore/GS", "linear_present_mode", std::clamp(UserInt(@"AMPS2BilinearPresent", 1), 0, 2));
	s_settings_interface->SetIntValue("EmuCore/GS", "texture_preloading", std::clamp(UserInt(@"AMPS2TexturePreloading", 2), 0, 2));
	s_settings_interface->SetBoolValue("EmuCore/GS", "hw_mipmap", UserBool(@"AMPS2HWMipmap", true));
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
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "WaitLoop", UserBool(@"AMPS2WaitLoop", true));
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "IntcStat", UserBool(@"AMPS2IntcStat", true));
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vuFlagHack", UserBool(@"AMPS2MVUFlag", true));
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vu1Instant", UserBool(@"AMPS2InstantVU1", true));
	s_settings_interface->SetBoolValue("EmuCore/Speedhacks", "vuThread", UserBool(@"AMPS2VUThread", false));
	s_settings_interface->SetBoolValue("Pad1", "Vibration", UserBool(@"AMPS2ControllerVibration", true));
	s_settings_interface->SetStringValue("SPU2/Output", "Backend", "SDL");
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
	EmuConfig.GS.Renderer = GSRendererType::Metal;
	EmuConfig.GS.AspectRatio = static_cast<AspectRatioType>(aspect_ratio);
	EmuConfig.CurrentAspectRatio = static_cast<AspectRatioType>(aspect_ratio);
	EmuConfig.GS.UpscaleMultiplier = upscale;
	EmuConfig.GS.VsyncEnable = UserBool(@"AMPS2VSync", false);
	EmuConfig.GS.FXAA = UserBool(@"AMPS2FXAA", false);
	EmuConfig.GS.IntegerScaling = UserBool(@"AMPS2IntegerScaling", false);
	EmuConfig.GS.TextureFiltering = static_cast<BiFiltering>(std::clamp(UserInt(@"AMPS2TextureFiltering", 2), 0, 3));
	EmuConfig.GS.InterlaceMode = static_cast<GSInterlaceMode>(std::clamp(UserInt(@"AMPS2InterlaceMode", 0), 0, 9));
	EmuConfig.GS.AccurateBlendingUnit = static_cast<AccBlendLevel>(std::clamp(UserInt(@"AMPS2AccurateBlending", 1), 0, 5));
	EmuConfig.GS.MaxAnisotropy = std::clamp(UserInt(@"AMPS2Anisotropy", 0), 0, 16);
	EmuConfig.GS.Dithering = std::clamp(UserInt(@"AMPS2Dithering", 2), 0, 3);
	EmuConfig.GS.LinearPresent = static_cast<GSPostBilinearMode>(std::clamp(UserInt(@"AMPS2BilinearPresent", 1), 0, 2));
	EmuConfig.GS.TexturePreloading = static_cast<TexturePreloadingLevel>(std::clamp(UserInt(@"AMPS2TexturePreloading", 2), 0, 2));
	EmuConfig.GS.HWMipmap = UserBool(@"AMPS2HWMipmap", true);
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
	EmuConfig.Speedhacks.WaitLoop = UserBool(@"AMPS2WaitLoop", true);
	EmuConfig.Speedhacks.IntcStat = UserBool(@"AMPS2IntcStat", true);
	EmuConfig.Speedhacks.vuFlagHack = UserBool(@"AMPS2MVUFlag", true);
	EmuConfig.Speedhacks.vu1Instant = UserBool(@"AMPS2InstantVU1", true);
	EmuConfig.Speedhacks.vuThread = UserBool(@"AMPS2VUThread", false);
	EmuConfig.SPU2.Backend = AudioBackend::SDL;
	EmuConfig.SPU2.OutputVolume = std::clamp(UserInt(@"AMPS2AudioVolume", 100), 0, 200);
	EmuConfig.SPU2.OutputMuted = !UserBool(@"AMPS2AudioEnabled", true);
	GSConfig = EmuConfig.GS;
	GSConfig.Renderer = GSRendererType::Metal;
	GSConfig.UpscaleMultiplier = upscale;
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

	ApplyAmethystUserSettings();

	if (!bios_path.empty())
	{
		const std::string bios_dir(Path::GetDirectory(bios_path));
		const std::string bios_file(Path::GetFileName(bios_path));
		NSLog(@"[ARMSX2] BIOS dir=%s file=%s", bios_dir.c_str(), bios_file.c_str());
		s_settings_interface->SetStringValue("Folders", "Bios", bios_dir.c_str());
		s_settings_interface->SetStringValue("Filenames", "BIOS", bios_file.c_str());
	}

	VMManager::Internal::LoadStartupSettings();
	ApplyAmethystUserSettings();
	VMManager::ApplySettings();
	GSConfig.Renderer = GSRendererType::Metal;
	if (MTGS::IsOpen())
		MTGS::ApplySettings();
	VMManager::ReloadInputSources();
	VMManager::ReloadInputBindings(true);
	s_settings_interface->Save();
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

	EmuFolders::AppRoot = s_data_root;
	EmuFolders::DataRoot = s_data_root;
	if (!s_resources_root.empty())
		EmuFolders::Resources = s_resources_root;
	else
		EmuFolders::SetResourcesDirectory();

	const std::string ini_path = Path::Combine(s_data_root, "PCSX2-Amethyst.ini");
	s_settings_interface = std::make_unique<INISettingsInterface>(ini_path);
	Host::Internal::SetBaseSettingsLayer(s_settings_interface.get());
	s_settings_interface->Load();
	if (s_settings_interface->IsEmpty())
		ConfigureDefaultSettings(*s_settings_interface);

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
	s_running = true;
	s_stop_requested = false;
	AppendBridgeLog("RunVM iso=" + iso_path + " bios=" + bios_path);
	ApplyRuntimeSettings(bios_path);
	EnsureDefaultMemoryCards();

	VMBootParameters boot_params;
	boot_params.filename = std::move(iso_path);

	if (!VMManager::Internal::CPUThreadInitialize())
	{
		SetLastError("CPUThreadInitialize failed");
		VMManager::Internal::CPUThreadShutdown();
		s_running = false;
		return;
	}

	VMManager::ApplySettings();
	GSDumpReplayer::SetIsDumpRunner(false);

	if (!VMManager::Initialize(boot_params))
	{
		SetLastError("VMManager::Initialize failed");
		VMManager::Internal::CPUThreadShutdown();
		s_running = false;
		return;
	}

	VMManager::SetState(VMState::Running);
	AppendBridgeLog("VM running");
	while (!s_stop_requested)
	{
		DrainCPUThreadTasks();
		const VMState state = VMManager::GetState();
		if (state == VMState::Stopping || state == VMState::Shutdown)
			break;
		if (state == VMState::Running)
			VMManager::Execute();
		else
			std::this_thread::sleep_for(std::chrono::milliseconds(250));
	}

	VMManager::Shutdown(false);
	VMManager::Internal::CPUThreadShutdown();
	DrainCPUThreadTasks();
	t_on_cpu_thread = false;
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
	if (s_running)
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
	return s_running ? 1 : 0;
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
void Host::BeginPresentFrame() {}
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
		NSLog(@"[ARMSX2] %.*s", static_cast<int>(message.size()), message.data());
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
void Host::OnPerformanceMetricsUpdated() {}
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
