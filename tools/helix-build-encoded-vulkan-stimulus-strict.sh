#!/usr/bin/env bash
set -euo pipefail

BASE_TOOLING="9fe49dbcc65534b08a8537aa85a855aa399b6a98"
SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "$repo_root"

for c in git python3 timeout grep; do
  command -v "$c" >/dev/null 2>&1 || { echo "error: missing command $c" >&2; exit 2; }
done

tmp="$(mktemp)"
cleanup(){ rm -f "$tmp"; }
trap cleanup EXIT INT TERM

git cat-file -e "${BASE_TOOLING}^{commit}" 2>/dev/null || git fetch origin "$BASE_TOOLING"
git show "${BASE_TOOLING}:tools/helix-build-encoded-vulkan-stimulus.sh" >"$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

# 1) Bound the header search and use the system OpenXR headers selected by the
# everything preset when present.
old='''WORKTREE="$BUILD_ROOT/worktree"
hdr=""
for root in /usr/include "$WORKTREE/build-everything" "$WORKTREE"; do
  [[ -e "$root" ]] || continue
  hdr="$(find "$root" -type f -path '*/openxr/openxr_platform.h' -print -quit 2>/dev/null || true)"
  [[ -n "$hdr" ]] && break
done
[[ -n "$hdr" ]] || fail "OpenXR platform headers not found"
inc="$(dirname "$(dirname "$hdr")")"
'''
new='''WORKTREE="$BUILD_ROOT/worktree"
echo '[preflight] Resolving OpenXR headers from bounded locations'
hdr=""
if [[ -f /usr/include/openxr/openxr_platform.h ]]; then
  hdr=/usr/include/openxr/openxr_platform.h
elif [[ -d "$WORKTREE/build-everything/_deps" ]]; then
  hdr="$(timeout 5s find "$WORKTREE/build-everything/_deps" -type f -path '*/openxr/openxr_platform.h' -print -quit 2>/dev/null || true)"
fi
[[ -n "$hdr" ]] || fail "OpenXR platform headers not found in bounded locations"
inc="$(dirname "$(dirname "$hdr")")"
echo "[preflight] OpenXR include root: $inc"
'''
if old not in s: raise SystemExit('error: header-search anchor missing')
s=s.replace(old,new,1)

# 2) Vulkan types must be visible before openxr_platform.h. Use the base KHR
# binding/image structs; these are the ABI structs aliased by enable2 headers.
old_inc='''#define XR_USE_GRAPHICS_API_VULKAN
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <vulkan/vulkan.h>
'''
new_inc='''#define XR_USE_GRAPHICS_API_VULKAN
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
'''
if old_inc not in s: raise SystemExit('error: include-order anchor missing')
s=s.replace(old_inc,new_inc,1)
s=s.replace('XrGraphicsBindingVulkan2KHR', 'XrGraphicsBindingVulkanKHR')
s=s.replace('XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR', 'XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR')
s=s.replace('XrSwapchainImageVulkan2KHR', 'XrSwapchainImageVulkanKHR')
s=s.replace('XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR', 'XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR')

# 3) Avoid pipefail/SIGPIPE from awk early exit and bound the compile.
old3="OPENXR_LIB=\"$(ldconfig -p | awk '/libopenxr_loader\\.so\\.1/{print $NF; exit}')\""
new3="OPENXR_LIB=\"$(ldconfig -p | awk '/libopenxr_loader\\.so\\.1/ && !found {value=$NF; found=1} END {if(found) print value}')\""
old4="VULKAN_LIB=\"$(ldconfig -p | awk '/libvulkan\\.so\\.1/{print $NF; exit}')\""
new4="VULKAN_LIB=\"$(ldconfig -p | awk '/libvulkan\\.so\\.1/ && !found {value=$NF; found=1} END {if(found) print value}')\""
if old3 not in s or old4 not in s: raise SystemExit('error: loader lookup anchor missing')
s=s.replace(old3,new3,1).replace(old4,new4,1)
needle='''[[ -n "$OPENXR_LIB" && -f "$OPENXR_LIB" ]] || fail "runtime OpenXR loader library not found"\n[[ -n "$VULKAN_LIB" && -f "$VULKAN_LIB" ]] || fail "runtime Vulkan loader library not found"\n'''
if needle not in s: raise SystemExit('error: loader validation anchor missing')
s=s.replace(needle, needle + '''echo "[preflight] OpenXR loader: $OPENXR_LIB"\necho "[preflight] Vulkan loader: $VULKAN_LIB"\n''',1)
old_compile='''echo '[1/3] Compiling graphics-bound Vulkan/OpenXR stimulus'\nc++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"\n'''
new_compile='''echo '[1/3] Compiling graphics-bound Vulkan/OpenXR stimulus'\ntimeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"\n'''
if old_compile not in s: raise SystemExit('error: compile anchor missing')
s=s.replace(old_compile,new_compile,1)

# 4) Replace the uniform-color stimulus with two deterministic high-entropy
# stereo patterns resident in one host-visible staging buffer. This avoids a
# nominally successful 220-frame run whose H.264 P frames are too small to arm
# the >=16-shard RTX8/GAP9 injection gate.
cmd_anchor='''    VkCommandBuffer cmd = VK_NULL_HANDLE;\n    vk_ok(vkAllocateCommandBuffers(device, &cbai, &cmd), "vkAllocateCommandBuffers");\n'''
if cmd_anchor not in s: raise SystemExit('error: command-buffer anchor missing')
staging=cmd_anchor + r'''

    const VkDeviceSize layer_bytes = VkDeviceSize(width) * VkDeviceSize(height) * 4;
    const VkDeviceSize pattern_bytes = layer_bytes * 2;
    const VkDeviceSize upload_bytes = pattern_bytes * 2;
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
    if (!coherent) mem_type = find_memory_type(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (mem_type == UINT32_MAX) die("no_host_visible_staging_memory");
    VkMemoryAllocateInfo mai{};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mem_type;
    VkDeviceMemory staging_memory = VK_NULL_HANDLE;
    vk_ok(vkAllocateMemory(device, &mai, nullptr, &staging_memory), "vkAllocateMemory_staging");
    vk_ok(vkBindBufferMemory(device, staging_buffer, staging_memory, 0), "vkBindBufferMemory_staging");
    void * mapped = nullptr;
    vk_ok(vkMapMemory(device, staging_memory, 0, upload_bytes, 0, &mapped), "vkMapMemory_staging");
    uint32_t seed = 0x6d2b79f5u;
    auto * words = static_cast<uint32_t *>(mapped);
    const VkDeviceSize word_count = upload_bytes / sizeof(uint32_t);
    for (VkDeviceSize i = 0; i < word_count; ++i)
    {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        words[i] = seed | 0xff000000u;
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
    std::fprintf(stderr, "HELIX_VULKAN_ENTROPY patterns=2 upload_bytes=%llu\n",
                 static_cast<unsigned long long>(upload_bytes));
    std::fflush(stderr);
'''
s=s.replace(cmd_anchor,staging,1)

clear='''        float phase = float(produced % 60) / 59.0f;\n        VkClearColorValue clear{{phase, 0.2f, 1.0f - phase, 1.0f}};\n        VkImageSubresourceRange range{}; range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT; range.levelCount = 1; range.layerCount = 2;\n        vkCmdClearColorImage(cmd, images[image_index].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);\n'''
copy=r'''        const VkDeviceSize pattern_offset = (produced & 1u) ? pattern_bytes : 0;
        std::array<VkBufferImageCopy, 2> copies{};
        for (uint32_t eye = 0; eye < 2; ++eye)
        {
            copies[eye].bufferOffset = pattern_offset + layer_bytes * eye;
            copies[eye].imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            copies[eye].imageSubresource.mipLevel = 0;
            copies[eye].imageSubresource.baseArrayLayer = eye;
            copies[eye].imageSubresource.layerCount = 1;
            copies[eye].imageExtent = {width, height, 1};
        }
        vkCmdCopyBufferToImage(cmd, staging_buffer, images[image_index].image,
                               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                               uint32_t(copies.size()), copies.data());
'''
if clear not in s: raise SystemExit('error: uniform-clear anchor missing')
s=s.replace(clear,copy,1)

cleanup='''    vkDeviceWaitIdle(device);\n    vkDestroyCommandPool(device, command_pool, nullptr);\n'''
cleanup_new='''    vkDeviceWaitIdle(device);\n    vkUnmapMemory(device, staging_memory);\n    vkDestroyBuffer(device, staging_buffer, nullptr);\n    vkFreeMemory(device, staging_memory, nullptr);\n    vkDestroyCommandPool(device, command_pool, nullptr);\n'''
if cleanup not in s: raise SystemExit('error: cleanup anchor missing')
s=s.replace(cleanup,cleanup_new,1)

old_markers='''for marker in XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME xrCreateSwapchain xrAcquireSwapchainImage vkCmdClearColorImage xrLocateViews XrCompositionLayerProjection xrEndFrame HELIX_VULKAN_DONE; do\n'''
new_markers='''for marker in XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME xrCreateSwapchain xrAcquireSwapchainImage vkCmdCopyBufferToImage HELIX_VULKAN_ENTROPY xrLocateViews XrCompositionLayerProjection xrEndFrame HELIX_VULKAN_DONE; do\n'''
if old_markers not in s: raise SystemExit('error: static marker anchor missing')
s=s.replace(old_markers,new_markers,1)

# Final generated-helper guards.
for forbidden in [
    'for root in /usr/include "$WORKTREE/build-everything" "$WORKTREE"',
    'print $NF; exit',
    'vkCmdClearColorImage',
    'XrGraphicsBindingVulkan2KHR',
    'XrSwapchainImageVulkan2KHR',
]:
    if forbidden in s: raise SystemExit(f'error: stale forbidden pattern remains: {forbidden}')
for required in [
    'timeout 5s find "$WORKTREE/build-everything/_deps"',
    '45s c++',
    'XrGraphicsBindingVulkanKHR',
    'XrSwapchainImageVulkanKHR',
    'vkCmdCopyBufferToImage',
    'HELIX_VULKAN_ENTROPY',
]:
    if required not in s: raise SystemExit(f'error: required pattern missing: {required}')
p.write_text(s)
PY

# Audit the exact generated build helper before executing it.
grep -Fq '[preflight] Resolving OpenXR headers from bounded locations' "$tmp"
grep -Fq 'timeout 5s find "$WORKTREE/build-everything/_deps"' "$tmp"
grep -Fq '45s c++' "$tmp"
grep -Fq 'XrGraphicsBindingVulkanKHR' "$tmp"
grep -Fq 'XrSwapchainImageVulkanKHR' "$tmp"
grep -Fq 'vkCmdCopyBufferToImage' "$tmp"
grep -Fq 'HELIX_VULKAN_ENTROPY' "$tmp"
! grep -Fq 'vkCmdClearColorImage' "$tmp"
! grep -Fq 'XR_MND_headless' "$tmp"

echo '[STRICT BUILD 1/1] Building exact graphics-bound high-entropy Vulkan stimulus only'
bash "$tmp"

BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$BUILD_ROOT/helix_vulkan_stimulus.cpp"
BIN="$BUILD_ROOT/helix-vulkan-stimulus"
META="$BUILD_ROOT/vulkan-stimulus-metadata.txt"
[[ -s "$SRC" && -x "$BIN" && -s "$META" ]] || { echo 'error: final stimulus artifact set incomplete' >&2; exit 2; }
grep -Fq 'source_commit=5568963b538eaae708b9f957a9a3c162ddaf5de4' "$META"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-projection-layer' "$META"
grep -Fq 'runtime_status=NOT_RUN' "$META"
grep -Fq 'HELIX_VULKAN_ENTROPY' "$SRC"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC"
grep -Fq 'XrGraphicsBindingVulkanKHR' "$SRC"
grep -Fq 'XrSwapchainImageVulkanKHR' "$SRC"
! grep -Fq 'vkCmdClearColorImage' "$SRC"
! grep -Fq 'XR_MND_headless' "$SRC"
printf '\nPASS: strict build-only Vulkan stimulus artifact gate.\nsource_commit=%s\nvulkan_stimulus=%s\nstimulus_source=%s\nmetadata=%s\nSTATUS: built only; runtime not executed.\n' "$SOURCE_COMMIT" "$BIN" "$SRC" "$META"
