// SPDX-FileCopyrightText: 2026 Amethyst
// SPDX-License-Identifier: GPL-3.0+

#include "common/CocoaTools.h"
#include "common/Darwin/DarwinMisc.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/WindowInfo.h"

#include "pcsx2/CDVD/CDVDdiscReader.h"
#include "pcsx2/Host/AudioStream.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/VMManager.h"

#include <fcntl.h>
#include <unistd.h>

#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#import <UIKit/UIKit.h>

namespace CocoaTools
{
bool CreateMetalLayer(WindowInfo*) { return true; }
void DestroyMetalLayer(WindowInfo*) {}
std::optional<float> GetViewRefreshRate(const WindowInfo& wi)
{
	if (wi.surface_refresh_rate > 0.0f)
		return wi.surface_refresh_rate;
	return static_cast<float>(UIScreen.mainScreen.maximumFramesPerSecond);
}
void AddThemeChangeHandler(void*, void (*)(void*)) {}
void RemoveThemeChangeHandler(void*) {}
void MarkHelpMenu(void*) {}
std::optional<std::string> GetBundlePath()
{
	NSString* path = NSBundle.mainBundle.bundlePath;
	return path ? std::optional<std::string>(path.UTF8String) : std::nullopt;
}
std::optional<std::string> GetNonTranslocatedBundlePath() { return GetBundlePath(); }
std::optional<std::string> MoveToTrash(std::string_view) { return std::nullopt; }
bool DelayedLaunch(std::string_view) { return false; }
bool ShowInFinder(std::string_view) { return false; }
std::optional<std::string> GetResourcePath()
{
	NSString* path = NSBundle.mainBundle.resourcePath;
	return path ? std::optional<std::string>(path.UTF8String) : std::nullopt;
}
void* CreateWindow(std::string_view, uint32_t, uint32_t) { return nullptr; }
void DestroyWindow(void*) {}
void GetWindowInfoFromWindow(WindowInfo*, void*) {}
void RunCocoaEventLoop(bool) {}
void StopMainThreadEventLoop() {}
} // namespace CocoaTools

namespace DarwinMisc
{
std::vector<CPUClass> GetCPUClasses()
{
	return {{"iOS", 1, 1}};
}
} // namespace DarwinMisc

namespace FileSystem
{
int OpenFDFileContent(const char* filename)
{
	if (!filename)
		return -1;
	return open(filename, O_RDONLY);
}
} // namespace FileSystem

std::vector<std::string> GetOpticalDriveList()
{
	return {};
}

void GetValidDrive(std::string& drive)
{
	drive.clear();
}

IOCtlSrc::IOCtlSrc(std::string filename)
	: m_filename(std::move(filename))
{
}

IOCtlSrc::~IOCtlSrc() = default;

bool IOCtlSrc::Reopen(Error* error)
{
	Error::SetStringView(error, "Optical drive passthrough is unavailable on iOS.");
	return false;
}

u32 IOCtlSrc::GetSectorCount() const
{
	return 0;
}

const std::vector<toc_entry>& IOCtlSrc::ReadTOC() const
{
	static const std::vector<toc_entry> empty_toc;
	return empty_toc;
}

bool IOCtlSrc::ReadSectors2048(u32, u32, u8*) const
{
	return false;
}

bool IOCtlSrc::ReadSectors2352(u32, u32, u8*) const
{
	return false;
}

bool IOCtlSrc::ReadTrackSubQ(cdvdSubQ* subq) const
{
	if (subq)
		std::memset(subq, 0, sizeof(*subq));
	return false;
}

u32 IOCtlSrc::GetLayerBreakAddress() const
{
	return 0;
}

s32 IOCtlSrc::GetMediaType() const
{
	return CDVD_TYPE_NODISC;
}

void IOCtlSrc::SetSpindleSpeed(bool) const
{
}

bool IOCtlSrc::DiscReady()
{
	return false;
}

std::unique_ptr<AudioStream> AudioStream::CreateOboeAudioStream(
	u32 sample_rate, const AudioStreamParameters& parameters, bool stretch_enabled, Error* error)
{
	Error::SetStringView(error, "Oboe audio is unavailable on iOS.");
	return nullptr;
}

const HotkeyInfo g_common_hotkeys[] = {
	{nullptr, nullptr, nullptr, nullptr},
};

const HotkeyInfo g_host_hotkeys[] = {
	{nullptr, nullptr, nullptr, nullptr},
};

namespace VMManager::Internal
{
void ResetVMHotkeyState()
{
}
} // namespace VMManager::Internal
