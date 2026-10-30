#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
META="$BUILD_ROOT/resume-metadata.txt"
OUT="$BUILD_ROOT"

fail(){ echo "error: $*" >&2; exit 2; }
for c in c++ find grep dirname realpath; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$META" ]] || fail "missing encoded artifact metadata: $META"
grep -Fq "source_commit=$SOURCE_COMMIT" "$META" || fail "artifact metadata source commit mismatch"
grep -Fq 'provenance=PASS direct-executable-build-graph' "$META" || fail "desktop provenance marker missing"
grep -Fq 'artifact_gate=PASS salvaged-existing-desktop-plus-apk-headless' "$META" || fail "encoded artifact gate marker missing"
SERVER="$(sed -n 's/^server=//p' "$META" | tail -1)"
MANIFEST="$(sed -n 's/^openxr_manifest=//p' "$META" | tail -1)"
APK="$(sed -n 's/^apk=//p' "$META" | tail -1)"
[[ -x "$SERVER" && -s "$MANIFEST" && -s "$APK" ]] || fail "frozen encoded artifact set incomplete"

SRC="$OUT/helix_vulkan_stimulus.cpp"
BIN="$OUT/helix-vulkan-stimulus"
cat >"$SRC" <<'CPP'
#define XR_USE_GRAPHICS_API_VULKAN
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
    if (XR_FAILED(r)) die(what, r);
}
static void vk_ok(VkResult r, const char * what)
{
    if (r != VK_SUCCESS) die(what, XR_SUCCESS, r);
}

template <typename T>
static void xr_init(T & v, XrStructureType type)
{
    v = {};
    v.type = type;
}

int main(int argc, char ** argv)
{
    uint32_t target_frames = 220;
    if (argc > 1) target_frames = uint32_t(std::stoul(argv[1]));

    uint32_t ext_count = 0;
    xr_ok(xrEnumerateInstanceExtensionProperties(nullptr, 0, &ext_count, nullptr), "xrEnumerateInstanceExtensionProperties_count");
    std::vector<XrExtensionProperties> exts(ext_count);
    for (auto & e : exts) xr_init(e, XR_TYPE_EXTENSION_PROPERTIES);
    xr_ok(xrEnumerateInstanceExtensionProperties(nullptr, ext_count, &ext_count, exts.data()), "xrEnumerateInstanceExtensionProperties_values");
    const char * vulkan_ext = XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME;
    bool has_vulkan = false;
    for (const auto & e : exts) if (std::strcmp(e.extensionName, vulkan_ext) == 0) has_vulkan = true;
    std::fprintf(stderr, "HELIX_VULKAN_EXT name=%s supported=%d\n", vulkan_ext, has_vulkan);
    std::fflush(stderr);
    if (!has_vulkan) die("XR_KHR_vulkan_enable2_unavailable");

    XrInstanceCreateInfo ici{}; xr_init(ici, XR_TYPE_INSTANCE_CREATE_INFO);
    std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "%s", "Helix Vulkan Stimulus");
    ici.applicationInfo.applicationVersion = 1;
    std::snprintf(ici.applicationInfo.engineName, XR_MAX_ENGINE_NAME_SIZE, "%s", "Helix");
    ici.applicationInfo.engineVersion = 1;
    ici.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
    ici.enabledExtensionCount = 1;
    ici.enabledExtensionNames = &vulkan_ext;
    XrInstance instance = XR_NULL_HANDLE;
    xr_ok(xrCreateInstance(&ici, &instance), "xrCreateInstance");

    auto load = [&](const char * name, auto & fn) {
        PFN_xrVoidFunction raw = nullptr;
        XrResult r = xrGetInstanceProcAddr(instance, name, &raw);
        if (XR_FAILED(r) || !raw) die(name, r);
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(raw);
    };
    PFN_xrGetVulkanGraphicsRequirements2KHR get_vk_req = nullptr;
    PFN_xrCreateVulkanInstanceKHR create_vk_instance = nullptr;
    PFN_xrGetVulkanGraphicsDevice2KHR get_vk_phys = nullptr;
    PFN_xrCreateVulkanDeviceKHR create_vk_device = nullptr;
    load("xrGetVulkanGraphicsRequirements2KHR", get_vk_req);
    load("xrCreateVulkanInstanceKHR", create_vk_instance);
    load("xrGetVulkanGraphicsDevice2KHR", get_vk_phys);
    load("xrCreateVulkanDeviceKHR", create_vk_device);

    XrSystemGetInfo sgi{}; xr_init(sgi, XR_TYPE_SYSTEM_GET_INFO);
    sgi.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    xr_ok(xrGetSystem(instance, &sgi, &system), "xrGetSystem");

    XrGraphicsRequirementsVulkan2KHR req{}; xr_init(req, XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR);
    xr_ok(get_vk_req(instance, system, &req), "xrGetVulkanGraphicsRequirements2KHR");

    VkApplicationInfo vai{};
    vai.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    vai.pApplicationName = "Helix Vulkan Stimulus";
    vai.applicationVersion = 1;
    vai.pEngineName = "Helix";
    vai.engineVersion = 1;
    vai.apiVersion = std::min<uint32_t>(VK_API_VERSION_1_2, req.maxApiVersionSupported);
    if (vai.apiVersion < req.minApiVersionSupported) vai.apiVersion = req.minApiVersionSupported;
    VkInstanceCreateInfo vici{};
    vici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    vici.pApplicationInfo = &vai;
    XrVulkanInstanceCreateInfoKHR xvici{}; xr_init(xvici, XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR);
    xvici.systemId = system;
    xvici.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    xvici.vulkanCreateInfo = &vici;
    VkInstance vk_instance = VK_NULL_HANDLE;
    VkResult vk_result = VK_SUCCESS;
    xr_ok(create_vk_instance(instance, &xvici, &vk_instance, &vk_result), "xrCreateVulkanInstanceKHR");
    vk_ok(vk_result, "vkCreateInstance_runtime");

    XrVulkanGraphicsDeviceGetInfoKHR gdgi{}; xr_init(gdgi, XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR);
    gdgi.systemId = system;
    gdgi.vulkanInstance = vk_instance;
    VkPhysicalDevice phys = VK_NULL_HANDLE;
    xr_ok(get_vk_phys(instance, &gdgi, &phys), "xrGetVulkanGraphicsDevice2KHR");

    uint32_t qcount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qcount, nullptr);
    std::vector<VkQueueFamilyProperties> qprops(qcount);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qcount, qprops.data());
    uint32_t qfam = UINT32_MAX;
    for (uint32_t i = 0; i < qcount; ++i) if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qfam = i; break; }
    if (qfam == UINT32_MAX) die("no_graphics_queue");
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
    XrVulkanDeviceCreateInfoKHR xvdci{}; xr_init(xvdci, XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR);
    xvdci.systemId = system;
    xvdci.pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    xvdci.vulkanPhysicalDevice = phys;
    xvdci.vulkanCreateInfo = &vdci;
    VkDevice device = VK_NULL_HANDLE;
    xr_ok(create_vk_device(instance, &xvdci, &device, &vk_result), "xrCreateVulkanDeviceKHR");
    vk_ok(vk_result, "vkCreateDevice_runtime");
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, qfam, 0, &queue);

    XrGraphicsBindingVulkan2KHR binding{}; xr_init(binding, XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR);
    binding.instance = vk_instance;
    binding.physicalDevice = phys;
    binding.device = device;
    binding.queueFamilyIndex = qfam;
    binding.queueIndex = 0;
    XrSessionCreateInfo sci{}; xr_init(sci, XR_TYPE_SESSION_CREATE_INFO);
    sci.next = &binding;
    sci.systemId = system;
    XrSession session = XR_NULL_HANDLE;
    xr_ok(xrCreateSession(instance, &sci, &session), "xrCreateSession");

    XrReferenceSpaceCreateInfo rsci{}; xr_init(rsci, XR_TYPE_REFERENCE_SPACE_CREATE_INFO);
    rsci.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    rsci.poseInReferenceSpace.orientation.w = 1.0f;
    XrSpace space = XR_NULL_HANDLE;
    xr_ok(xrCreateReferenceSpace(session, &rsci, &space), "xrCreateReferenceSpace");

    uint32_t view_count = 0;
    xr_ok(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &view_count, nullptr), "xrEnumerateViewConfigurationViews_count");
    if (view_count != 2) die("expected_two_views");
    std::vector<XrViewConfigurationView> view_cfg(view_count);
    for (auto & v : view_cfg) xr_init(v, XR_TYPE_VIEW_CONFIGURATION_VIEW);
    xr_ok(xrEnumerateViewConfigurationViews(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, view_count, &view_count, view_cfg.data()), "xrEnumerateViewConfigurationViews_values");

    uint32_t fmt_count = 0;
    xr_ok(xrEnumerateSwapchainFormats(session, 0, &fmt_count, nullptr), "xrEnumerateSwapchainFormats_count");
    std::vector<int64_t> fmts(fmt_count);
    xr_ok(xrEnumerateSwapchainFormats(session, fmt_count, &fmt_count, fmts.data()), "xrEnumerateSwapchainFormats_values");
    std::array<VkFormat,4> wanted{VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM};
    VkFormat color_format = VK_FORMAT_UNDEFINED;
    for (VkFormat w : wanted) if (std::find(fmts.begin(), fmts.end(), int64_t(w)) != fmts.end()) { color_format = w; break; }
    if (color_format == VK_FORMAT_UNDEFINED) die("no_supported_color_format");

    uint32_t width = std::max(view_cfg[0].recommendedImageRectWidth, view_cfg[1].recommendedImageRectWidth);
    uint32_t height = std::max(view_cfg[0].recommendedImageRectHeight, view_cfg[1].recommendedImageRectHeight);
    XrSwapchainCreateInfo xsc{}; xr_init(xsc, XR_TYPE_SWAPCHAIN_CREATE_INFO);
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
    std::vector<XrSwapchainImageVulkan2KHR> images(image_count);
    for (auto & image : images) xr_init(image, XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR);
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

    bool running = false;
    bool stopping = false;
    auto startup_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (!running && std::chrono::steady_clock::now() < startup_deadline) {
        XrEventDataBuffer event{}; xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
        while (xrPollEvent(instance, &event) == XR_SUCCESS) {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
                std::fprintf(stderr, "HELIX_VULKAN_STATE state=%d\n", int(changed->state)); std::fflush(stderr);
                if (changed->state == XR_SESSION_STATE_READY) {
                    XrSessionBeginInfo bi{}; xr_init(bi, XR_TYPE_SESSION_BEGIN_INFO);
                    bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                    xr_ok(xrBeginSession(session, &bi), "xrBeginSession");
                    running = true;
                }
            }
            xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
        }
        if (!running) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (!running) die("session_never_ready");

    std::vector<XrView> views(view_count);
    for (auto & v : views) xr_init(v, XR_TYPE_VIEW);
    std::array<XrCompositionLayerProjectionView,2> proj{};
    for (auto & p : proj) xr_init(p, XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW);

    uint32_t produced = 0;
    for (; produced < target_frames; ++produced) {
        XrFrameWaitInfo fwi{}; xr_init(fwi, XR_TYPE_FRAME_WAIT_INFO);
        XrFrameState fs{}; xr_init(fs, XR_TYPE_FRAME_STATE);
        xr_ok(xrWaitFrame(session, &fwi, &fs), "xrWaitFrame");
        XrFrameBeginInfo fbi{}; xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);
        xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");

        XrSwapchainImageAcquireInfo ai{}; xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);
        uint32_t image_index = 0;
        xr_ok(xrAcquireSwapchainImage(swapchain, &ai, &image_index), "xrAcquireSwapchainImage");
        XrSwapchainImageWaitInfo wi{}; xr_init(wi, XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO); wi.timeout = XR_INFINITE_DURATION;
        xr_ok(xrWaitSwapchainImage(swapchain, &wi), "xrWaitSwapchainImage");

        vk_ok(vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer");
        VkCommandBufferBeginInfo cbi{}; cbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO; cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
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
        float phase = float(produced % 60) / 59.0f;
        VkClearColorValue clear{{phase, 0.2f, 1.0f - phase, 1.0f}};
        VkImageSubresourceRange range{}; range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT; range.levelCount = 1; range.layerCount = 2;
        vkCmdClearColorImage(cmd, images[image_index].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);
        VkImageMemoryBarrier to_color = to_transfer;
        to_color.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        to_color.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        to_color.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_color.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr, 1, &to_color);
        vk_ok(vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
        VkSubmitInfo si{}; si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO; si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        vk_ok(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE), "vkQueueSubmit");
        vk_ok(vkQueueWaitIdle(queue), "vkQueueWaitIdle");
        XrSwapchainImageReleaseInfo ri{}; xr_init(ri, XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO);
        xr_ok(xrReleaseSwapchainImage(swapchain, &ri), "xrReleaseSwapchainImage");

        XrViewLocateInfo vli{}; xr_init(vli, XR_TYPE_VIEW_LOCATE_INFO);
        vli.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        vli.displayTime = fs.predictedDisplayTime;
        vli.space = space;
        XrViewState vs{}; xr_init(vs, XR_TYPE_VIEW_STATE);
        uint32_t located = 0;
        xr_ok(xrLocateViews(session, &vli, &vs, view_count, &located, views.data()), "xrLocateViews");
        if (located != 2) die("xrLocateViews_not_two");
        for (uint32_t i = 0; i < 2; ++i) {
            proj[i].pose = views[i].pose;
            proj[i].fov = views[i].fov;
            proj[i].subImage.swapchain = swapchain;
            proj[i].subImage.imageRect.offset = {0,0};
            proj[i].subImage.imageRect.extent = {int32_t(width), int32_t(height)};
            proj[i].subImage.imageArrayIndex = i;
        }
        XrCompositionLayerProjection layer{}; xr_init(layer, XR_TYPE_COMPOSITION_LAYER_PROJECTION);
        layer.space = space;
        layer.viewCount = 2;
        layer.views = proj.data();
        const XrCompositionLayerBaseHeader * layers[] = {reinterpret_cast<const XrCompositionLayerBaseHeader *>(&layer)};
        XrFrameEndInfo fei{}; xr_init(fei, XR_TYPE_FRAME_END_INFO);
        fei.displayTime = fs.predictedDisplayTime;
        fei.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        fei.layerCount = fs.shouldRender ? 1u : 0u;
        fei.layers = fs.shouldRender ? layers : nullptr;
        xr_ok(xrEndFrame(session, &fei), "xrEndFrame");
        if ((produced + 1) % 30 == 0) { std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u shouldRender=%d\n", produced + 1, fs.shouldRender); std::fflush(stderr); }
    }

    std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u\n", produced); std::fflush(stderr);
    xrRequestExitSession(session);
    auto stop_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (std::chrono::steady_clock::now() < stop_deadline && !stopping) {
        XrEventDataBuffer event{}; xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
        while (xrPollEvent(instance, &event) == XR_SUCCESS) {
            if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&event);
                if (changed->state == XR_SESSION_STATE_STOPPING) stopping = true;
            }
            xr_init(event, XR_TYPE_EVENT_DATA_BUFFER);
        }
        if (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (stopping) xrEndSession(session);
    vkDeviceWaitIdle(device);
    vkDestroyCommandPool(device, command_pool, nullptr);
    xrDestroySwapchain(swapchain);
    xrDestroySpace(space);
    xrDestroySession(session);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(vk_instance, nullptr);
    xrDestroyInstance(instance);
    return 0;
}
CPP

WORKTREE="$BUILD_ROOT/worktree"
hdr=""
for root in /usr/include "$WORKTREE/build-everything" "$WORKTREE"; do
  [[ -e "$root" ]] || continue
  hdr="$(find "$root" -type f -path '*/openxr/openxr_platform.h' -print -quit 2>/dev/null || true)"
  [[ -n "$hdr" ]] && break
done
[[ -n "$hdr" ]] || fail "OpenXR platform headers not found"
inc="$(dirname "$(dirname "$hdr")")"
[[ -f /usr/include/vulkan/vulkan.h || -f "$WORKTREE"/build-everything/_deps/*/include/vulkan/vulkan.h ]] || true

echo '[1/3] Compiling graphics-bound Vulkan/OpenXR stimulus'
c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$SRC" -lopenxr_loader -lvulkan -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "Vulkan stimulus build failed"

echo '[2/3] Static stimulus contract audit'
for marker in XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME xrCreateSwapchain xrAcquireSwapchainImage vkCmdClearColorImage xrLocateViews XrCompositionLayerProjection xrEndFrame HELIX_VULKAN_DONE; do
  grep -Fq "$marker" "$SRC" || fail "missing stimulus marker $marker"
done
if grep -Fq 'XR_MND_headless' "$SRC"; then fail "headless extension leaked into graphics stimulus"; fi

echo '[3/3] Recording frozen stimulus metadata'
cat >"$OUT/vulkan-stimulus-metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
server=$SERVER
openxr_manifest=$MANIFEST
apk=$APK
vulkan_stimulus=$BIN
stimulus_contract=PASS graphics-bound-vulkan-projection-layer
server_artifact_gate=PASS reused-frozen-encoded-artifacts
runtime_status=NOT_RUN
EOF
printf '\nPASS: graphics-bound Vulkan/OpenXR stimulus built against frozen encoded artifacts.\nsource_commit=%s\nvulkan_stimulus=%s\nevidence=%s\nSTATUS: stimulus built only; Quest encoded runtime not executed.\n' "$SOURCE_COMMIT" "$BIN" "$OUT"
