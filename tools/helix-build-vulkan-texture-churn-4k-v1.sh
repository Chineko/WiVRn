#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-v1"
META="$ROOT/vulkan-texture-churn-4k-v1-metadata.txt"
BANK_META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
BANK_SEAL="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-seal.txt"
BANK_SOURCE_SHA="8cb614a1bdff0be412b58503c301674372272ff9485a963122eb8d9f3e22fecb"
BANK_BINARY_SHA="3e7aa0d617fcbbd933eea54ed4edee66e966a76c82db6ae11a5ef8afa4b0f0f9"
BANK_METADATA_SHA="c8de14bec0d1e46fc1dd059ff6b80f033e8f69dae9db880d58cbe69e87286ccf"
BANK_BUILD_TOOLING="ec7661c38898e0c1faab5374e2057014866b4ba8"
WIDTH=4096
HEIGHT=4096
INTERVAL_MS=2000
MAX_CYCLES=180
TEXTURE_BYTES=$((WIDTH * HEIGHT * 4))

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk c++ file grep ldd sha256sum timeout; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BANK_META" "$BANK_SEAL"; do [[ -s "$f" ]] || fail "missing frozen bank32 artifact: $f"; done
[[ "$(sha256sum "$BANK_META" | awk '{print $1}')" == "$BANK_METADATA_SHA" ]] || fail "bank32 metadata hash mismatch"
grep -Fqx "source_sha256=$BANK_SOURCE_SHA" "$BANK_SEAL" || fail "bank32 seal source hash mismatch"
grep -Fqx "binary_sha256=$BANK_BINARY_SHA" "$BANK_SEAL" || fail "bank32 seal binary hash mismatch"
grep -Fqx "metadata_sha256=$BANK_METADATA_SHA" "$BANK_SEAL" || fail "bank32 seal metadata hash mismatch"
grep -Fqx "build_tooling_commit=$BANK_BUILD_TOOLING" "$BANK_SEAL" || fail "bank32 build tooling mismatch"
grep -Fqx 'texture_bank_patterns=32' "$BANK_SEAL" || fail "bank32 pattern count mismatch"
grep -Fqx 'texture_bank_multiplier=4' "$BANK_SEAL" || fail "bank32 multiplier mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps' "$BANK_SEAL" || fail "bank32 seal marker missing"

VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BANK_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing from bank32 metadata"

cat >"$SRC" <<'CPP'
#include <vulkan/vulkan.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <thread>
#include <vector>

static volatile std::sig_atomic_t g_stop = 0;
static void on_signal(int){ g_stop = 1; }
static void die(const char *m, VkResult r = VK_SUCCESS){
    if (r == VK_SUCCESS) std::fprintf(stderr,"HELIX_CHURN_ERROR %s\n",m);
    else std::fprintf(stderr,"HELIX_CHURN_ERROR %s vk=%d\n",m,int(r));
    std::exit(2);
}
static void vkcheck(VkResult r, const char *m){ if(r != VK_SUCCESS) die(m,r); }

static uint32_t find_memory_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags required){
    VkPhysicalDeviceMemoryProperties mp{};
    vkGetPhysicalDeviceMemoryProperties(pd,&mp);
    for(uint32_t i=0;i<mp.memoryTypeCount;i++)
        if((bits & (1u<<i)) && (mp.memoryTypes[i].propertyFlags & required) == required) return i;
    die("memory_type_not_found");
    return 0;
}

int main(){
    constexpr uint32_t W=4096, H=4096;
    constexpr VkDeviceSize BYTES=VkDeviceSize(W)*VkDeviceSize(H)*4u;
    constexpr uint32_t INTERVAL_MS=2000;
    constexpr uint32_t MAX_CYCLES=180;
    std::signal(SIGINT,on_signal); std::signal(SIGTERM,on_signal);

    VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    ai.pApplicationName="helix-vulkan-texture-churn-4k-v1";
    ai.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ici.pApplicationInfo=&ai;
    VkInstance instance=VK_NULL_HANDLE; vkcheck(vkCreateInstance(&ici,nullptr,&instance),"vkCreateInstance");

    uint32_t ndev=0; vkcheck(vkEnumeratePhysicalDevices(instance,&ndev,nullptr),"enumerate_count");
    if(!ndev) die("no_physical_device");
    std::vector<VkPhysicalDevice> pds(ndev); vkcheck(vkEnumeratePhysicalDevices(instance,&ndev,pds.data()),"enumerate_devices");
    VkPhysicalDevice pd=pds[0]; int best=-1;
    for(auto cand:pds){
        VkPhysicalDeviceProperties pr{}; vkGetPhysicalDeviceProperties(cand,&pr);
        int score=(pr.vendorID==0x10de?100:0)+(pr.deviceType==VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU?10:0);
        if(score>best){ best=score; pd=cand; }
    }
    VkPhysicalDeviceProperties props{}; vkGetPhysicalDeviceProperties(pd,&props);
    uint32_t nq=0; vkGetPhysicalDeviceQueueFamilyProperties(pd,&nq,nullptr);
    std::vector<VkQueueFamilyProperties> qps(nq); vkGetPhysicalDeviceQueueFamilyProperties(pd,&nq,qps.data());
    uint32_t qf=UINT32_MAX;
    for(uint32_t i=0;i<nq;i++) if(qps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT){ qf=i; break; }
    if(qf==UINT32_MAX) for(uint32_t i=0;i<nq;i++) if(qps[i].queueFlags & VK_QUEUE_TRANSFER_BIT){ qf=i; break; }
    if(qf==UINT32_MAX) die("no_transfer_queue_family");
    float pri=1.0f; VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qci.queueFamilyIndex=qf; qci.queueCount=1; qci.pQueuePriorities=&pri;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dci.queueCreateInfoCount=1; dci.pQueueCreateInfos=&qci;
    VkDevice dev=VK_NULL_HANDLE; vkcheck(vkCreateDevice(pd,&dci,nullptr,&dev),"vkCreateDevice");
    VkQueue queue=VK_NULL_HANDLE; vkGetDeviceQueue(dev,qf,0,&queue);

    VkBufferCreateInfo bci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; bci.size=BYTES; bci.usage=VK_BUFFER_USAGE_TRANSFER_SRC_BIT; bci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer staging=VK_NULL_HANDLE; vkcheck(vkCreateBuffer(dev,&bci,nullptr,&staging),"create_staging");
    VkMemoryRequirements br{}; vkGetBufferMemoryRequirements(dev,staging,&br);
    VkMemoryAllocateInfo bai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; bai.allocationSize=br.size; bai.memoryTypeIndex=find_memory_type(pd,br.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory staging_mem=VK_NULL_HANDLE; vkcheck(vkAllocateMemory(dev,&bai,nullptr,&staging_mem),"alloc_staging");
    vkcheck(vkBindBufferMemory(dev,staging,staging_mem,0),"bind_staging");
    void *mapped=nullptr; vkcheck(vkMapMemory(dev,staging_mem,0,BYTES,0,&mapped),"map_staging");

    VkBufferCreateInfo rbi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; rbi.size=4; rbi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT; rbi.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer readback=VK_NULL_HANDLE; vkcheck(vkCreateBuffer(dev,&rbi,nullptr,&readback),"create_readback");
    VkMemoryRequirements rr{}; vkGetBufferMemoryRequirements(dev,readback,&rr);
    VkMemoryAllocateInfo rai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; rai.allocationSize=rr.size; rai.memoryTypeIndex=find_memory_type(pd,rr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory read_mem=VK_NULL_HANDLE; vkcheck(vkAllocateMemory(dev,&rai,nullptr,&read_mem),"alloc_readback");
    vkcheck(vkBindBufferMemory(dev,readback,read_mem,0),"bind_readback");
    uint32_t *read_ptr=nullptr; vkcheck(vkMapMemory(dev,read_mem,0,4,0,reinterpret_cast<void**>(&read_ptr)),"map_readback");

    VkCommandPoolCreateInfo pci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pci.queueFamilyIndex=qf; pci.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    VkCommandPool pool=VK_NULL_HANDLE; vkcheck(vkCreateCommandPool(dev,&pci,nullptr,&pool),"create_pool");
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; cai.commandPool=pool; cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount=1;
    VkCommandBuffer cmd=VK_NULL_HANDLE; vkcheck(vkAllocateCommandBuffers(dev,&cai,&cmd),"alloc_cmd");
    VkFenceCreateInfo fci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence=VK_NULL_HANDLE; vkcheck(vkCreateFence(dev,&fci,nullptr,&fence),"create_fence");

    std::printf("HELIX_CHURN_READY gpu_vendor=0x%04x gpu_device=0x%04x width=%u height=%u bytes=%llu interval_ms=%u max_cycles=%u\n",props.vendorID,props.deviceID,W,H,(unsigned long long)BYTES,INTERVAL_MS,MAX_CYCLES); std::fflush(stdout);
    uint32_t cycles=0, allocs=0, uploads=0, frees=0, verify_failures=0, errors=0;
    const auto start=std::chrono::steady_clock::now();
    for(uint32_t cycle=0; cycle<MAX_CYCLES && !g_stop; ++cycle){
        auto t0=std::chrono::steady_clock::now();
        uint32_t seed=0x9e3779b9u ^ (cycle*0x85ebca6bu);
        auto *words=static_cast<uint32_t*>(mapped); const size_t count=size_t(BYTES/4u);
        for(size_t i=0;i<count;i++){ seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; words[i]=0xff000000u | (seed & 0x00ffffffu); }
        const uint32_t expected=words[0]; *read_ptr=0;

        VkImageCreateInfo im{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; im.imageType=VK_IMAGE_TYPE_2D; im.format=VK_FORMAT_R8G8B8A8_UNORM; im.extent={W,H,1}; im.mipLevels=1; im.arrayLayers=1; im.samples=VK_SAMPLE_COUNT_1_BIT; im.tiling=VK_IMAGE_TILING_OPTIMAL; im.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT; im.sharingMode=VK_SHARING_MODE_EXCLUSIVE; im.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
        VkImage image=VK_NULL_HANDLE; VkResult r=vkCreateImage(dev,&im,nullptr,&image); if(r!=VK_SUCCESS){ errors++; std::fprintf(stderr,"HELIX_CHURN_ERROR cycle=%u create_image vk=%d\n",cycle+1,int(r)); break; }
        VkMemoryRequirements ir{}; vkGetImageMemoryRequirements(dev,image,&ir);
        VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.allocationSize=ir.size;
        try { mai.memoryTypeIndex=find_memory_type(pd,ir.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT); }
        catch(...) { mai.memoryTypeIndex=find_memory_type(pd,ir.memoryTypeBits,0); }
        VkDeviceMemory mem=VK_NULL_HANDLE; r=vkAllocateMemory(dev,&mai,nullptr,&mem); if(r!=VK_SUCCESS){ vkDestroyImage(dev,image,nullptr); errors++; std::fprintf(stderr,"HELIX_CHURN_ERROR cycle=%u alloc_image_memory vk=%d bytes=%llu\n",cycle+1,int(r),(unsigned long long)ir.size); break; }
        allocs++;
        if((r=vkBindImageMemory(dev,image,mem,0))!=VK_SUCCESS){ vkFreeMemory(dev,mem,nullptr); vkDestroyImage(dev,image,nullptr); errors++; std::fprintf(stderr,"HELIX_CHURN_ERROR cycle=%u bind_image vk=%d\n",cycle+1,int(r)); break; }
        vkcheck(vkResetCommandBuffer(cmd,0),"reset_cmd"); VkCommandBufferBeginInfo cbi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; cbi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; vkcheck(vkBeginCommandBuffer(cmd,&cbi),"begin_cmd");
        VkImageMemoryBarrier b1{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; b1.srcAccessMask=0; b1.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; b1.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED; b1.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b1.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; b1.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; b1.image=image; b1.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&b1);
        VkBufferImageCopy copy{}; copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; copy.imageExtent={W,H,1}; vkCmdCopyBufferToImage(cmd,staging,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
        VkImageMemoryBarrier b2{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER}; b2.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; b2.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT; b2.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b2.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL; b2.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; b2.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; b2.image=image; b2.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&b2);
        VkBufferImageCopy back{}; back.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}; back.imageExtent={1,1,1}; vkCmdCopyImageToBuffer(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,readback,1,&back);
        vkcheck(vkEndCommandBuffer(cmd),"end_cmd"); vkcheck(vkResetFences(dev,1,&fence),"reset_fence"); VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO}; si.commandBufferCount=1; si.pCommandBuffers=&cmd; vkcheck(vkQueueSubmit(queue,1,&si,fence),"queue_submit"); r=vkWaitForFences(dev,1,&fence,VK_TRUE,5000000000ull); if(r!=VK_SUCCESS){ errors++; std::fprintf(stderr,"HELIX_CHURN_ERROR cycle=%u fence_wait vk=%d\n",cycle+1,int(r)); vkDeviceWaitIdle(dev); vkFreeMemory(dev,mem,nullptr); vkDestroyImage(dev,image,nullptr); break; }
        uploads++;
        bool verify=(*read_ptr==expected); if(!verify) verify_failures++;
        vkDestroyImage(dev,image,nullptr); vkFreeMemory(dev,mem,nullptr); frees++; cycles++;
        auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-t0).count();
        std::printf("HELIX_CHURN_CYCLE cycle=%u bytes=%llu alloc_bytes=%llu verify=%s elapsed_ms=%lld\n",cycles,(unsigned long long)BYTES,(unsigned long long)ir.size,verify?"PASS":"FAIL",(long long)ms); std::fflush(stdout);
        if(!verify){ errors++; break; }
        auto next=start+std::chrono::milliseconds(uint64_t(cycle+1)*INTERVAL_MS); std::this_thread::sleep_until(next);
    }
    vkDeviceWaitIdle(dev);
    vkDestroyFence(dev,fence,nullptr); vkDestroyCommandPool(dev,pool,nullptr); vkUnmapMemory(dev,read_mem); vkDestroyBuffer(dev,readback,nullptr); vkFreeMemory(dev,read_mem,nullptr); vkUnmapMemory(dev,staging_mem); vkDestroyBuffer(dev,staging,nullptr); vkFreeMemory(dev,staging_mem,nullptr); vkDestroyDevice(dev,nullptr); vkDestroyInstance(instance,nullptr);
    std::printf("HELIX_CHURN_SUMMARY cycles=%u allocations=%u uploads=%u frees=%u verify_failures=%u errors=%u terminated=%s\n",cycles,allocs,uploads,frees,verify_failures,errors,g_stop?"signal":"complete"); std::fflush(stdout);
    return errors?3:0;
}
CPP

# Source audit: exactly one 4K image at a time, persistent staging/readback, upload + readback verification, explicit destroy/free.
grep -Fq 'constexpr uint32_t W=4096, H=4096;' "$SRC" || fail "4K geometry missing"
grep -Fq 'constexpr uint32_t INTERVAL_MS=2000;' "$SRC" || fail "2s cadence missing"
grep -Fq 'constexpr uint32_t MAX_CYCLES=180;' "$SRC" || fail "cycle cap missing"
grep -Fq 'VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT' "$SRC" || fail "image transfer usage missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload copy missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback verification missing"
grep -Fq 'vkDestroyImage(dev,image,nullptr); vkFreeMemory(dev,mem,nullptr); frees++; cycles++;' "$SRC" || fail "destroy/free lifecycle missing"
grep -Fq 'HELIX_CHURN_SUMMARY' "$SRC" || fail "summary marker missing"

# Reject accidental extra churn axes: staging/readback are created once outside the cycle loop.
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "unexpected buffer creation count"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "unexpected image creation call count"

echo '[1/2] Compiling deterministic 4K Vulkan texture churn companion'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "4K texture churn compile failed"
file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "churn binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

echo '[2/2] Recording deterministic churn metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"; BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
cat >"$META" <<EOF
bank32_source_sha256=$BANK_SOURCE_SHA
bank32_binary_sha256=$BANK_BINARY_SHA
bank32_metadata_sha256=$BANK_METADATA_SHA
bank32_build_tooling=$BANK_BUILD_TOOLING
texture_width=$WIDTH
texture_height=$HEIGHT
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=$TEXTURE_BYTES
interval_ms=$INTERVAL_MS
max_cycles=$MAX_CYCLES
live_images=1
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
churn_contract=PASS deterministic-single-4k-rgba-device-memory-lifecycle-upload-readback-v1
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"; [[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"
printf '\nPASS: deterministic 4K Vulkan texture churn companion built.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\ntexture=4096x4096 RGBA8\ntexture_bytes=%s\ninterval_ms=%s\nmax_cycles=%s\nlive_images=1\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$TEXTURE_BYTES" "$INTERVAL_MS" "$MAX_CYCLES"
