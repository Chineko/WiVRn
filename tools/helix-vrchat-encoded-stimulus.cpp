// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from the local sealed Vulkan stimulus; see encoded workload audit.
#define XR_USE_GRAPHICS_API_VULKAN
#define XR_USE_TIMESPEC
#include "helix-stimulus-pattern.h"
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

[[noreturn]] static void die(const char * msg, XrResult xr = XR_SUCCESS, VkResult vk = VK_SUCCESS)
{
	std::fprintf(stderr, "HELIX_VULKAN_FAIL message=%s xr=%d vk=%d\n", msg, int(xr), int(vk));
	std::fflush(stderr);
	std::exit(2);
}
static void xr_ok(XrResult r, const char * what)
{
	if (XR_FAILED(r))
		die(what, r);
}
static void vk_ok(VkResult r, const char * what)
{
	if (r != VK_SUCCESS)
		die(what, XR_SUCCESS, r);
}
template <typename T>
static void xr_init(T & v, XrStructureType type)
{
	v = {};
	v.type = type;
}

int main(int argc, char ** argv)
{
	if (argc != 2)
		die("usage_absolute_frame_schedule");
	struct Frame
	{
		long long at;
		unsigned bytes[2];
	};
	std::vector<Frame> schedule;
	std::ifstream input(argv[1]);
	std::string line;
	if (!std::getline(input, line) || line != "HELIX_ENCODED_FRAMES 1")
		die("bad_frame_schedule");
	while (std::getline(input, line))
	{
		Frame f{};
		std::string extra;
		std::istringstream row(line);
		if (!(row >> f.at >> f.bytes[0] >> f.bytes[1]) || row >> extra ||
		    f.at < 0 || f.at > 1800000000LL || (!schedule.empty() && f.at <= schedule.back().at) ||
		    f.bytes[0] < 4000 || f.bytes[1] < 4000 || f.bytes[0] > 61440 || f.bytes[1] > 61440 || schedule.size() >= 162001)
			die("invalid_frame_schedule");
		schedule.push_back(f);
	}
	if (!input.eof() || schedule.size() < 900)
		die("empty_truncated_frame_schedule");
	const uint32_t target_frames = uint32_t(schedule.size());

	uint32_t ext_count = 0;
	xr_ok(xrEnumerateInstanceExtensionProperties(nullptr, 0, &ext_count, nullptr), "xrEnumerateInstanceExtensionProperties_count");
	std::vector<XrExtensionProperties> exts(ext_count);
	for (auto & e: exts)
		xr_init(e, XR_TYPE_EXTENSION_PROPERTIES);
	xr_ok(xrEnumerateInstanceExtensionProperties(nullptr, ext_count, &ext_count, exts.data()), "xrEnumerateInstanceExtensionProperties_values");
	const char * vulkan_ext = XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME;
	const char * time_ext = XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME;
	bool has_vulkan = false;
	bool has_time = false;
	for (const auto & e: exts)
	{
		if (std::strcmp(e.extensionName, vulkan_ext) == 0)
			has_vulkan = true;
		if (std::strcmp(e.extensionName, time_ext) == 0)
			has_time = true;
	}
	std::fprintf(stderr, "HELIX_VULKAN_EXT name=%s supported=%d\n", vulkan_ext, has_vulkan);
	std::fflush(stderr);
	if (!has_vulkan)
		die("XR_KHR_vulkan_enable2_unavailable");
	if (!has_time)
		die("XR_KHR_convert_timespec_time_unavailable");

	XrInstanceCreateInfo ici{};
	xr_init(ici, XR_TYPE_INSTANCE_CREATE_INFO);
	std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "%s", "Helix Vulkan Stimulus");
	ici.applicationInfo.applicationVersion = 1;
	std::snprintf(ici.applicationInfo.engineName, XR_MAX_ENGINE_NAME_SIZE, "%s", "Helix");
	ici.applicationInfo.engineVersion = 1;
	ici.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
	const char * enabled_exts[] = {vulkan_ext, time_ext};
	ici.enabledExtensionCount = 2;
	ici.enabledExtensionNames = enabled_exts;
	XrInstance instance = XR_NULL_HANDLE;
	xr_ok(xrCreateInstance(&ici, &instance), "xrCreateInstance");

	auto load = [&](const char * name, auto & fn) {
		PFN_xrVoidFunction raw = nullptr;
		XrResult r = xrGetInstanceProcAddr(instance, name, &raw);
		if (XR_FAILED(r) || !raw)
			die(name, r);
		fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(raw);
	};
	PFN_xrGetVulkanGraphicsRequirements2KHR get_vk_req = nullptr;
	PFN_xrConvertTimeToTimespecTimeKHR to_timespec = nullptr;
	load("xrConvertTimeToTimespecTimeKHR", to_timespec);
	PFN_xrCreateVulkanInstanceKHR create_vk_instance = nullptr;
	PFN_xrGetVulkanGraphicsDevice2KHR get_vk_phys = nullptr;
	PFN_xrCreateVulkanDeviceKHR create_vk_device = nullptr;
	load("xrGetVulkanGraphicsRequirements2KHR", get_vk_req);
	load("xrCreateVulkanInstanceKHR", create_vk_instance);
	load("xrGetVulkanGraphicsDevice2KHR", get_vk_phys);
	load("xrCreateVulkanDeviceKHR", create_vk_device);

	XrSystemGetInfo sgi{};
	xr_init(sgi, XR_TYPE_SYSTEM_GET_INFO);
	sgi.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
	XrSystemId system = XR_NULL_SYSTEM_ID;
	xr_ok(xrGetSystem(instance, &sgi, &system), "xrGetSystem");

	XrGraphicsRequirementsVulkan2KHR req{};
	xr_init(req, XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR);
	xr_ok(get_vk_req(instance, system, &req), "xrGetVulkanGraphicsRequirements2KHR");
	auto xr_version_to_vk = [](XrVersion v) {
		return VK_MAKE_VERSION(uint32_t(XR_VERSION_MAJOR(v)), uint32_t(XR_VERSION_MINOR(v)), uint32_t(XR_VERSION_PATCH(v)));
	};
	const uint32_t min_vk_api = xr_version_to_vk(req.minApiVersionSupported);
	const uint32_t max_vk_api = xr_version_to_vk(req.maxApiVersionSupported);
	uint32_t chosen_vk_api = std::min<uint32_t>(VK_API_VERSION_1_2, max_vk_api);
	if (chosen_vk_api < min_vk_api)
		chosen_vk_api = min_vk_api;

	VkApplicationInfo vai{};
	vai.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
	vai.pApplicationName = "Helix Vulkan Stimulus";
	vai.applicationVersion = 1;
	vai.pEngineName = "Helix";
	vai.engineVersion = 1;
	vai.apiVersion = chosen_vk_api;
	VkInstanceCreateInfo vici{};
	vici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	vici.pApplicationInfo = &vai;
	XrVulkanInstanceCreateInfoKHR xvici{};
	xr_init(xvici, XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR);
	xvici.systemId = system;
	xvici.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
	xvici.vulkanCreateInfo = &vici;
	VkInstance vk_instance = VK_NULL_HANDLE;
	VkResult vk_result = VK_SUCCESS;
	xr_ok(create_vk_instance(instance, &xvici, &vk_instance, &vk_result), "xrCreateVulkanInstanceKHR");
	vk_ok(vk_result, "vkCreateInstance_runtime");

	XrVulkanGraphicsDeviceGetInfoKHR gdgi{};
	xr_init(gdgi, XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR);
	gdgi.systemId = system;
	gdgi.vulkanInstance = vk_instance;
	VkPhysicalDevice phys = VK_NULL_HANDLE;
	xr_ok(get_vk_phys(instance, &gdgi, &phys), "xrGetVulkanGraphicsDevice2KHR");

	uint32_t qcount = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(phys, &qcount, nullptr);
	std::vector<VkQueueFamilyProperties> qprops(qcount);
	vkGetPhysicalDeviceQueueFamilyProperties(phys, &qcount, qprops.data());
	uint32_t qfam = UINT32_MAX;
	for (uint32_t i = 0; i < qcount; ++i)
		if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)
		{
			qfam = i;
			break;
		}
	if (qfam == UINT32_MAX)
		die("no_graphics_queue");
	float priority = 1.0f;
	VkDeviceQueueCreateInfo qci{};
	qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
	qci.queueFamilyIndex = qfam;
	qci.queueCount = 1;
	qci.pQueuePriorities = &priority;
	VkDeviceCreateInfo vdci{};
	vdci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
	vdci.queueCreateInfoCount = 1;
	vdci.pQueueCreateInfos = &qci;
	XrVulkanDeviceCreateInfoKHR xvdci{};
	xr_init(xvdci, XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR);
	xvdci.systemId = system;
	xvdci.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
	xvdci.vulkanPhysicalDevice = phys;
	xvdci.vulkanCreateInfo = &vdci;
	VkDevice device = VK_NULL_HANDLE;
	xr_ok(create_vk_device(instance, &xvdci, &device, &vk_result), "xrCreateVulkanDeviceKHR");
	vk_ok(vk_result, "vkCreateDevice_runtime");
	VkQueue queue = VK_NULL_HANDLE;
	vkGetDeviceQueue(device, qfam, 0, &queue);

	XrGraphicsBindingVulkanKHR binding{};
	xr_init(binding, XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR);
	binding.instance = vk_instance;
	binding.physicalDevice = phys;
	binding.device = device;
	binding.queueFamilyIndex = qfam;
	binding.queueIndex = 0;
	XrSessionCreateInfo sci{};
	xr_init(sci, XR_TYPE_SESSION_CREATE_INFO);
	sci.next = &binding;
	sci.systemId = system;
	XrSession session = XR_NULL_HANDLE;
	xr_ok(xrCreateSession(instance, &sci, &session), "xrCreateSession");

	XrReferenceSpaceCreateInfo rsci{};
	xr_init(rsci, XR_TYPE_REFERENCE_SPACE_CREATE_INFO);
	rsci.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
	rsci.poseInReferenceSpace.orientation.w = 1.0f;
	XrSpace space = XR_NULL_HANDLE;
	xr_ok(xrCreateReferenceSpace(session, &rsci, &space), "xrCreateReferenceSpace");

	uint32_t view_count = 0;
	xr_ok(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &view_count, nullptr), "xrEnumerateViewConfigurationViews_count");
	if (view_count != 2)
		die("expected_two_views");
	std::vector<XrViewConfigurationView> view_cfg(view_count);
	for (auto & v: view_cfg)
		xr_init(v, XR_TYPE_VIEW_CONFIGURATION_VIEW);
	xr_ok(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, view_count, &view_count, view_cfg.data()), "xrEnumerateViewConfigurationViews_values");

	uint32_t fmt_count = 0;
	xr_ok(xrEnumerateSwapchainFormats(session, 0, &fmt_count, nullptr), "xrEnumerateSwapchainFormats_count");
	std::vector<int64_t> fmts(fmt_count);
	xr_ok(xrEnumerateSwapchainFormats(session, fmt_count, &fmt_count, fmts.data()), "xrEnumerateSwapchainFormats_values");
	std::array<VkFormat, 4> wanted{VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM};
	VkFormat color_format = VK_FORMAT_UNDEFINED;
	for (VkFormat w: wanted)
		if (std::find(fmts.begin(), fmts.end(), int64_t(w)) != fmts.end())
		{
			color_format = w;
			break;
		}
	if (color_format == VK_FORMAT_UNDEFINED)
		die("no_supported_color_format");

	uint32_t width = std::max(view_cfg[0].recommendedImageRectWidth, view_cfg[1].recommendedImageRectWidth);
	uint32_t height = std::max(view_cfg[0].recommendedImageRectHeight, view_cfg[1].recommendedImageRectHeight);
	XrSwapchainCreateInfo xsc{};
	xr_init(xsc, XR_TYPE_SWAPCHAIN_CREATE_INFO);
	xsc.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
	xsc.format = int64_t(color_format);
	xsc.sampleCount = 1;
	xsc.width = width;
	xsc.height = height;
	xsc.faceCount = 1;
	xsc.arraySize = 2;
	xsc.mipCount = 1;
	XrSwapchain swapchain = XR_NULL_HANDLE;
	xr_ok(xrCreateSwapchain(session, &xsc, &swapchain), "xrCreateSwapchain");

	uint32_t image_count = 0;
	xr_ok(xrEnumerateSwapchainImages(swapchain, 0, &image_count, nullptr), "xrEnumerateSwapchainImages_count");
	std::vector<XrSwapchainImageVulkanKHR> images(image_count);
	for (auto & image: images)
		xr_init(image, XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR);
	xr_ok(xrEnumerateSwapchainImages(swapchain, image_count, &image_count, reinterpret_cast<XrSwapchainImageBaseHeader *>(images.data())), "xrEnumerateSwapchainImages_values");

	VkCommandPoolCreateInfo cpci{};
	cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	cpci.queueFamilyIndex = qfam;
	VkCommandPool command_pool = VK_NULL_HANDLE;
	vk_ok(vkCreateCommandPool(device, &cpci, nullptr, &command_pool), "vkCreateCommandPool");
	VkCommandBufferAllocateInfo cbai{};
	cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	cbai.commandPool = command_pool;
	cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	cbai.commandBufferCount = 1;
	VkCommandBuffer cmd = VK_NULL_HANDLE;
	vk_ok(vkAllocateCommandBuffers(device, &cbai, &cmd), "vkAllocateCommandBuffers");

	const VkDeviceSize layer_bytes = VkDeviceSize(width) * VkDeviceSize(height) * 4;
	const VkDeviceSize pattern_bytes = layer_bytes * 2;
	const VkDeviceSize upload_bytes = pattern_bytes * 32;
	VkBufferCreateInfo bci{};
	bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
	bci.size = upload_bytes;
	bci.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
	bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	VkBuffer staging_buffer = VK_NULL_HANDLE;
	vk_ok(vkCreateBuffer(device, &bci, nullptr, &staging_buffer), "vkCreateBuffer_staging");
	VkMemoryRequirements mr{};
	vkGetBufferMemoryRequirements(device, staging_buffer, &mr);
	VkPhysicalDeviceMemoryProperties mp{};
	vkGetPhysicalDeviceMemoryProperties(phys, &mp);
	auto find_memory_type = [&](VkMemoryPropertyFlags flags) {
		for (uint32_t i = 0; i < mp.memoryTypeCount; ++i)
			if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags)
				return i;
		return UINT32_MAX;
	};
	uint32_t mem_type = find_memory_type(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	bool coherent = mem_type != UINT32_MAX;
	if (!coherent)
		mem_type = find_memory_type(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
	if (mem_type == UINT32_MAX)
		die("no_host_visible_staging_memory");
	VkMemoryAllocateInfo mai{};
	mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = mem_type;
	VkDeviceMemory staging_memory = VK_NULL_HANDLE;
	vk_ok(vkAllocateMemory(device, &mai, nullptr, &staging_memory), "vkAllocateMemory_staging");
	vk_ok(vkBindBufferMemory(device, staging_buffer, staging_memory, 0), "vkBindBufferMemory_staging");
	void * mapped = nullptr;
	vk_ok(vkMapMemory(device, staging_memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory_staging");
	auto * words = static_cast<uint32_t *>(mapped);

	for (uint32_t pattern = 0; pattern < 32u; ++pattern)
	{
		uint32_t seed = helix_stimulus::noise_seed;
		for (uint32_t eye = 0; eye < 2u; ++eye)
		{
			for (uint32_t y = 0; y < height; ++y)
			{
				for (uint32_t x = 0; x < width; ++x)
				{
					const auto noise = helix_stimulus::next_noise(seed);
					const auto rgb = helix_stimulus::pixel(helix_stimulus::base_pixel(eye, x, y), noise, pattern);
					const VkDeviceSize pixel =
					        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +
					        VkDeviceSize(y) * VkDeviceSize(width) + x;
					words[pixel] = 0xff000000u | rgb;
				}
			}
		}
	}
	if (!coherent)
	{
		VkMappedMemoryRange flush{};
		flush.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
		flush.memory = staging_memory;
		flush.offset = 0;
		flush.size = VK_WHOLE_SIZE;
		vk_ok(vkFlushMappedMemoryRanges(device, 1, &flush), "vkFlushMappedMemoryRanges_staging");
	}
	std::fprintf(stderr, "HELIX_VULKAN_ENTROPY patterns=32 mapping=shared_noise_linear_blend_v2 upload_bytes=%llu\n", static_cast<unsigned long long>(upload_bytes));
	std::fflush(stderr);

	bool running = false;
	bool stopping = false;
	auto startup_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
	while (!running && std::chrono::steady_clock::now() < startup_deadline)
	{
		XrEventDataBuffer event{};
		xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
		while (xrPollEvent(instance, &event) == XR_SUCCESS)
		{
			if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
			{
				auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
				std::fprintf(stderr, "HELIX_VULKAN_STATE state=%d\n", int(changed->state));
				std::fflush(stderr);
				if (changed->state == XR_SESSION_STATE_READY)
				{
					XrSessionBeginInfo bi{};
					xr_init(bi, XR_TYPE_SESSION_BEGIN_INFO);
					bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
					xr_ok(xrBeginSession(session, &bi), "xrBeginSession");
					running = true;
				}
			}
			xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
		}
		if (!running)
			std::this_thread::sleep_for(std::chrono::milliseconds(10));
	}
	if (!running)
		die("session_never_ready");

	std::vector<XrView> views(view_count);
	for (auto & v: views)
		xr_init(v, XR_TYPE_VIEW);
	std::array<XrCompositionLayerProjectionView, 2> proj{};
	for (auto & p: proj)
		xr_init(p, XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW);

	uint32_t produced = 0;
	// Plan parser bounds this to 162001 entries; dump only after production.
	std::vector<int64_t> submitted_times;
	submitted_times.reserve(target_frames);
	uint32_t attempts = 0;
	XrSessionState session_state = XR_SESSION_STATE_READY;
	const auto production_origin = std::chrono::steady_clock::now();
	auto render_deadline = production_origin + std::chrono::microseconds(schedule.back().at) + std::chrono::seconds(30);
	while (produced < target_frames && std::chrono::steady_clock::now() < render_deadline)
	{
		XrEventDataBuffer frame_event{};
		xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);
		while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)
		{
			if (frame_event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
			{
				auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&frame_event);
				session_state = changed->state;
				std::fprintf(stderr, "HELIX_VULKAN_STATE state=%d\n", int(session_state));
				std::fflush(stderr);
				if (session_state == XR_SESSION_STATE_STOPPING || session_state == XR_SESSION_STATE_EXITING || session_state == XR_SESSION_STATE_LOSS_PENDING)
					die("session_stopped_before_render_target");
			}
			xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);
		}
		std::this_thread::sleep_until(production_origin + std::chrono::microseconds(schedule[produced].at));
		++attempts;
		XrFrameWaitInfo fwi{};
		xr_init(fwi, XR_TYPE_FRAME_WAIT_INFO);
		XrFrameState fs{};
		xr_init(fs, XR_TYPE_FRAME_STATE);
		xr_ok(xrWaitFrame(session, &fwi, &fs), "xrWaitFrame");
		XrFrameBeginInfo fbi{};
		xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);
		xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");
		if (!fs.shouldRender)
		{
			XrFrameEndInfo idle_end{};
			xr_init(idle_end, XR_TYPE_FRAME_END_INFO);
			idle_end.displayTime = fs.predictedDisplayTime;
			idle_end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
			idle_end.layerCount = 0;
			idle_end.layers = nullptr;
			xr_ok(xrEndFrame(session, &idle_end), "xrEndFrame_idle");
			if (attempts % 30 == 0)
			{
				std::fprintf(stderr, "HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d\n", attempts, produced, int(session_state));
				std::fflush(stderr);
			}
			continue;
		}

		XrSwapchainImageAcquireInfo ai{};
		xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);
		uint32_t image_index = 0;
		xr_ok(xrAcquireSwapchainImage(swapchain, &ai, &image_index), "xrAcquireSwapchainImage");
		XrSwapchainImageWaitInfo wi{};
		xr_init(wi, XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO);
		wi.timeout = XR_INFINITE_DURATION;
		xr_ok(xrWaitSwapchainImage(swapchain, &wi), "xrWaitSwapchainImage");

		vk_ok(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer");
		VkCommandBufferBeginInfo cbi{};
		cbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
		cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
		vk_ok(vkBeginCommandBuffer(cmd, &cbi), "vkBeginCommandBuffer");
		VkImageMemoryBarrier to_transfer{};
		to_transfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
		to_transfer.srcAccessMask = 0;
		to_transfer.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		to_transfer.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
		to_transfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		to_transfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		to_transfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
		to_transfer.image = images[image_index].image;
		to_transfer.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
		to_transfer.subresourceRange.baseMipLevel = 0;
		to_transfer.subresourceRange.levelCount = 1;
		to_transfer.subresourceRange.baseArrayLayer = 0;
		to_transfer.subresourceRange.layerCount = 2;
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &to_transfer);
		std::array<VkBufferImageCopy, 2> copies{};
		for (uint32_t eye = 0; eye < 2; ++eye)
		{
			const unsigned target = schedule[produced].bytes[eye];
			const unsigned level = std::min(31u, (target - 4000u) * 32u / (61440u - 4000u));
			copies[eye].bufferOffset = VkDeviceSize(level) * pattern_bytes + layer_bytes * eye;
			copies[eye].imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
			copies[eye].imageSubresource.mipLevel = 0;
			copies[eye].imageSubresource.baseArrayLayer = eye;
			copies[eye].imageSubresource.layerCount = 1;
			copies[eye].imageExtent = {width, height, 1};
		}
		vkCmdCopyBufferToImage(cmd, staging_buffer, images[image_index].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, uint32_t(copies.size()), copies.data());
		VkImageMemoryBarrier to_color = to_transfer;
		to_color.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
		to_color.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
		to_color.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		to_color.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr, 1, &to_color);
		vk_ok(vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
		VkSubmitInfo si{};
		si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
		si.commandBufferCount = 1;
		si.pCommandBuffers = &cmd;
		vk_ok(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE), "vkQueueSubmit");
		vk_ok(vkQueueWaitIdle(queue), "vkQueueWaitIdle");
		XrSwapchainImageReleaseInfo ri{};
		xr_init(ri, XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO);
		xr_ok(xrReleaseSwapchainImage(swapchain, &ri), "xrReleaseSwapchainImage");

		XrViewLocateInfo vli{};
		xr_init(vli, XR_TYPE_VIEW_LOCATE_INFO);
		vli.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
		vli.displayTime = fs.predictedDisplayTime;
		vli.space = space;
		XrViewState vs{};
		xr_init(vs, XR_TYPE_VIEW_STATE);
		uint32_t located = 0;
		xr_ok(xrLocateViews(session, &vli, &vs, view_count, &located, views.data()), "xrLocateViews");
		if (located != 2)
			die("xrLocateViews_not_two");
		for (uint32_t i = 0; i < 2; ++i)
		{
			proj[i].pose = views[i].pose;
			proj[i].fov = views[i].fov;
			proj[i].subImage.swapchain = swapchain;
			proj[i].subImage.imageRect.offset = {0, 0};
			proj[i].subImage.imageRect.extent = {int32_t(width), int32_t(height)};
			proj[i].subImage.imageArrayIndex = i;
		}
		XrCompositionLayerProjection layer{};
		xr_init(layer, XR_TYPE_COMPOSITION_LAYER_PROJECTION);
		layer.space = space;
		layer.viewCount = 2;
		layer.views = proj.data();
		const XrCompositionLayerBaseHeader * layers[] = {reinterpret_cast<const XrCompositionLayerBaseHeader *>(&layer)};
		XrFrameEndInfo fei{};
		xr_init(fei, XR_TYPE_FRAME_END_INFO);
		fei.displayTime = fs.predictedDisplayTime;
		fei.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
		fei.layerCount = 1;
		fei.layers = layers;
		xr_ok(xrEndFrame(session, &fei), "xrEndFrame");
		timespec source_time{};
		xr_ok(to_timespec(instance, fs.predictedDisplayTime, &source_time), "xrConvertTimeToTimespecTimeKHR");
		submitted_times.push_back(int64_t(source_time.tv_sec) * 1'000'000'000 + source_time.tv_nsec);
		++produced;
		if (produced % 30 == 0)
		{
			std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d\n", produced, attempts, int(session_state));
			std::fflush(stderr);
		}
	}
	if (produced != target_frames)
		die("renderable_frame_target_not_reached");
	for (uint32_t index = 0; index < produced; ++index)
		std::fprintf(stderr, "HELIX_STIMULUS_INPUT index=%u source_ns=%lld level0=%u level1=%u\n", index, (long long)submitted_times[index], std::min(31u, (schedule[index].bytes[0] - 4000u) * 32u / (61440u - 4000u)), std::min(31u, (schedule[index].bytes[1] - 4000u) * 32u / (61440u - 4000u)));

	std::fprintf(stderr, "HELIX_VULKAN_SCHEDULE elapsed_us=%lld expected_us=%lld\n", (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - production_origin).count(), schedule.back().at);
	std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u attempts=%u\n", produced, attempts);
	std::fflush(stderr);
	xrRequestExitSession(session);
	auto stop_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
	while (std::chrono::steady_clock::now() < stop_deadline && !stopping)
	{
		XrEventDataBuffer event{};
		xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
		while (xrPollEvent(instance, &event) == XR_SUCCESS)
		{
			if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
			{
				auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
				if (changed->state == XR_SESSION_STATE_STOPPING)
					stopping = true;
			}
			xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
		}
		if (!stopping)
			std::this_thread::sleep_for(std::chrono::milliseconds(10));
	}
	if (stopping)
		xrEndSession(session);
	vkDeviceWaitIdle(device);
	vkUnmapMemory(device, staging_memory);
	vkDestroyBuffer(device, staging_buffer, nullptr);
	vkFreeMemory(device, staging_memory, nullptr);
	vkDestroyCommandPool(device, command_pool, nullptr);
	xrDestroySwapchain(swapchain);
	xrDestroySpace(space);
	xrDestroySession(session);
	vkDestroyDevice(device, nullptr);
	vkDestroyInstance(vk_instance, nullptr);
	xrDestroyInstance(instance);
	return 0;
}
