add_library(ARMSX2AmethystBridge SHARED
	AmethystBridge.mm
	IOSPlatformStubs.mm
)

set_target_properties(ARMSX2AmethystBridge PROPERTIES
	OUTPUT_NAME "armsx2_amethyst"
)

target_link_libraries(ARMSX2AmethystBridge PRIVATE
	PCSX2
	PCSX2_FLAGS
	"-framework Foundation"
	"-framework UIKit"
	"-framework QuartzCore"
	"-framework Metal"
	"-framework GameController"
	"-framework CoreGraphics"
	"-framework CoreText"
)

target_link_directories(ARMSX2AmethystBridge PRIVATE
	"${CMAKE_SOURCE_DIR}/3rdparty/libs"
)
