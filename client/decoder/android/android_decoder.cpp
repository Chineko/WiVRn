/*
 * WiVRn VR streaming
 * Copyright (C) 2022  Guillaume Meunier <guillaume.meunier@centraliens.net>
 * Copyright (C) 2022  Patrick Nicolas <patricknicolas@laposte.net>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "android_decoder.h"
#include "application.h"
#include "scenes/stream.h"
#include "utils/named_thread.h"
#include <android/hardware_buffer.h>
#include <cassert>
#include <future>
#include <magic_enum.hpp>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <mutex>
#include <optional>
#include <ranges>
#include <spdlog/spdlog.h>
#include <thread>
#include <unordered_map>
#include <vulkan/vulkan.hpp>
#include <vulkan/vulkan_android.h>
#include <vulkan/vulkan_raii.hpp>

DEUGLIFY(AMediaFormat)

struct wivrn::android::decoder::mapped_hardware_buffer
{
	vk::raii::DeviceMemory memory = nullptr;
	vk::raii::Image vimage = nullptr;
	vk::Extent2D extent{};
	vk::raii::ImageView image_view = nullptr;
	vk::ImageLayout layout = vk::ImageLayout::eUndefined;
};

namespace
{
const char * mime(wivrn::video_codec codec)
{
	using c = wivrn::video_codec;
	switch (codec)
	{
		case c::h264:
			return "video/avc";
		case c::h265:
			return "video/hevc";
		case c::av1:
			return "video/av01";
		case c::raw:
			break;
	}
	assert(false);
	__builtin_unreachable();
}

void check(media_status_t status, const char * msg)
{
	if (status != AMEDIA_OK)
	{
		spdlog::error("{}: MediaCodec error {}", msg, (int)status);
		throw std::runtime_error("MediaCodec error");
	}
}

struct android_blit_handle : public decoder::blit_handle
{
	std::shared_ptr<wivrn::android::decoder::mapped_hardware_buffer> vk_data;
	std::shared_ptr<AImageReader> image_reader;
	AImage_ptr aimage;
	android_blit_handle(
	        const wivrn::from_headset::feedback & feedback,
	        const wivrn::to_headset::video_stream_data_shard::view_info_t & view_info,
	        vk::ImageView image_view,
	        vk::Image image,
	        vk::Extent2D extent,
	        vk::ImageLayout & current_layout,
	        decltype(vk_data) vk_data,
	        decltype(image_reader) image_reader,
	        decltype(aimage) aimage) :
	        decoder::blit_handle(feedback, view_info, image_view, image, extent, current_layout),
	        vk_data(vk_data),
	        image_reader(image_reader),
	        aimage(std::move(aimage)) {}
};

// Helix 0.1 keeps the wire protocol unchanged. Decoder-side failures are
// reported through the existing feedback path by replaying the most recent
// complete frame with sent_to_decoder cleared. The server's existing IDR
// handler therefore treats the failed decode chain like a lost reference frame.
struct helix_decoder_health
{
	std::mutex mutex;
	std::optional<wivrn::from_headset::feedback> last_complete_feedback;
	std::optional<uint64_t> first_submitted_frame;
	std::optional<uint64_t> last_decoded_frame;
	uint64_t last_recovery_request_frame = 0;
	uint64_t codec_generation = 0;
	unsigned recovery_requests = 0;
	bool recovery_pending = false;
	bool flush_attempted = false;
};

std::mutex helix_health_map_mutex;
std::unordered_map<wivrn::android::decoder *, std::shared_ptr<helix_decoder_health>> helix_health_map;

std::shared_ptr<helix_decoder_health> helix_health(wivrn::android::decoder * decoder)
{
	std::scoped_lock lock(helix_health_map_mutex);
	auto & state = helix_health_map[decoder];
	if (!state)
		state = std::make_shared<helix_decoder_health>();
	return state;
}

void helix_remove_health(wivrn::android::decoder * decoder)
{
	std::scoped_lock lock(helix_health_map_mutex);
	helix_health_map.erase(decoder);
}

uint64_t helix_codec_generation(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	return state->codec_generation;
}

bool helix_codec_generation_matches(wivrn::android::decoder * decoder, uint64_t generation)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	return state->codec_generation == generation;
}

void helix_note_decoded(wivrn::android::decoder * decoder, uint64_t frame_index)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	if (!state->last_decoded_frame || frame_index > *state->last_decoded_frame)
		state->last_decoded_frame = frame_index;
	if (state->recovery_pending && frame_index > state->last_recovery_request_frame)
	{
		spdlog::info("Helix decoder output resumed at frame {}", frame_index);
		state->recovery_pending = false;
		state->recovery_requests = 0;
		state->flush_attempted = false;
	}
}

void helix_request_recovery(
        wivrn::android::decoder * decoder,
        const std::weak_ptr<scenes::stream> & weak_scene,
        uint8_t stream_index,
        const char * reason,
        std::optional<uint64_t> preferred_frame = {})
{
	auto state = helix_health(decoder);
	std::optional<wivrn::from_headset::feedback> recovery_feedback;
	{
		std::scoped_lock lock(state->mutex);
		if (!state->last_complete_feedback)
		{
			spdlog::warn("Helix decoder recovery requested before any complete frame (stream {}): {}", stream_index, reason);
			return;
		}

		uint64_t frame_index = preferred_frame.value_or(state->last_complete_feedback->frame_index);
		// If output remains stalled, permit another IDR request after eight more
		// submitted frames. This bounds recovery latency without creating an IDR storm.
		if (state->recovery_pending && frame_index <= state->last_recovery_request_frame + 8)
			return;

		recovery_feedback = *state->last_complete_feedback;
		recovery_feedback->frame_index = frame_index;
		recovery_feedback->sent_to_decoder = 0;
		recovery_feedback->received_from_decoder = 0;
		recovery_feedback->blitted = 0;
		state->recovery_pending = true;
		state->last_recovery_request_frame = frame_index;
		state->recovery_requests++;
	}

	spdlog::warn("Helix requesting IDR for stream {} at frame {}: {}", stream_index, recovery_feedback->frame_index, reason);
	if (auto scene = weak_scene.lock())
		scene->send_feedback(*recovery_feedback);
}

bool helix_should_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	if (!state->recovery_pending || state->recovery_requests < 2 || state->flush_attempted)
		return false;

	state->flush_attempted = true;
	return true;
}

void helix_begin_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->codec_generation++;
}

void helix_reset_after_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->first_submitted_frame.reset();
	state->last_decoded_frame.reset();
	state->recovery_pending = false;
	state->recovery_requests = 0;
}

void helix_note_submitted(
        wivrn::android::decoder * decoder,
        const std::weak_ptr<scenes::stream> & weak_scene,
        uint8_t stream_index,
        const wivrn::from_headset::feedback & feedback)
{
	auto state = helix_health(decoder);
	bool stalled = false;
	{
		std::scoped_lock lock(state->mutex);
		state->last_complete_feedback = feedback;
		if (!state->first_submitted_frame)
			state->first_submitted_frame = feedback.frame_index;

		uint64_t outstanding_frames = 0;
		if (state->last_decoded_frame)
		{
			if (feedback.frame_index > *state->last_decoded_frame)
				outstanding_frames = feedback.frame_index - *state->last_decoded_frame;
		}
		else
		{
			outstanding_frames = feedback.frame_index - *state->first_submitted_frame + 1;
		}
		stalled = outstanding_frames > 4;
	}

	if (stalled)
		helix_request_recovery(decoder, weak_scene, stream_index, "decoder output stalled", feedback.frame_index);
}

} // namespace

namespace wivrn::android
{

decoder::decoder(
        vk::raii::Device & device,
        vk::raii::PhysicalDevice & physical_device,
        const wivrn::to_headset::video_stream_description & description,
        uint8_t stream_index,
        std::weak_ptr<scenes::stream> weak_scene,
        shard_accumulator * accumulator) :
        stream_index(stream_index), device(device), weak_scene(weak_scene), accumulator(accumulator)
{
	spdlog::info("hbm_mutex.native_handle() = {}", (void *)hbm_mutex.native_handle());

	auto width = description.width;
	auto height = description.height / (stream_index == 2 ? 2 : 1);

	AImageReader * ir;
	check(AImageReader_newWithUsage(
	              width,
	              height,
	              AIMAGE_FORMAT_PRIVATE,
	              AHARDWAREBUFFER_USAGE_CPU_READ_NEVER | AHARDWAREBUFFER_USAGE_CPU_WRITE_NEVER | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
	              scenes::stream::image_buffer_size + 4 /* maxImages */,
	              &ir),
	      "AImageReader_newWithUsage");
	image_reader.reset(ir, AImageReader_deleter{});

	AImageReader_ImageListener listener{this, on_image_available};
	check(AImageReader_setImageListener(ir, &listener), "AImageReader_setImageListener");

	vkGetAndroidHardwareBufferPropertiesANDROID =
	        application::get_vulkan_proc<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
	                "vkGetAndroidHardwareBufferPropertiesANDROID");
	{
		AMediaFormat_ptr format(AMediaFormat_new());
		AMediaFormat_setString(format.get(), AMEDIAFORMAT_KEY_MIME, mime(description.codec[stream_index]));
		// AMediaFormat_setInt32(format.get(), "vendor.qti-ext-dec-low-latency.enable", 1); // Qualcomm low
		// latency mode
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_WIDTH, width);
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_HEIGHT, height);
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_OPERATING_RATE, std::ceil(description.frame_rate));
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_PRIORITY, 0);

		media_codec.reset(AMediaCodec_createDecoderByType(mime(description.codec[stream_index])));

		if (not media_codec)
			throw std::runtime_error(std::string("Cannot create decoder for MIME type ") + mime(description.codec[stream_index]));

		char * codec_name;
		check(AMediaCodec_getName(media_codec.get(), &codec_name), "AMediaCodec_getName");
		spdlog::info("Created MediaCodec decoder \"{}\"", codec_name);
		AMediaCodec_releaseName(media_codec.get(), codec_name);

		ANativeWindow * window;

		check(AImageReader_getWindow(image_reader.get(), &window), "AImageReader_getWindow");

		AMediaCodecOnAsyncNotifyCallback callback{
		        .onAsyncInputAvailable = decoder::on_media_input_available,
		        .onAsyncOutputAvailable = decoder::on_media_output_available,
		        .onAsyncFormatChanged = decoder::on_media_format_changed,
		        .onAsyncError = decoder::on_media_error,
		};
		check(AMediaCodec_setAsyncNotifyCallback(media_codec.get(), callback, this),
		      "AMediaCodec_setAsyncNotifyCallback");

		check(AMediaCodec_configure(media_codec.get(), format.get(), window, nullptr /* crypto */, 0 /* flags */),
		      "AMediaCodec_configure");

		check(AMediaCodec_start(media_codec.get()), "AMediaCodec_start");
	}
	worker = utils::named_thread(
	        "decoder-" + std::to_string(stream_index),
	        [this]() {
		        while (true)
		        {
			        try
			        {
				        if (jobs.pop()())
					        return;
			        }
			        catch (const utils::sync_queue_closed & e)
			        {
				        return;
			        }
			        catch (const std::exception & e)
			        {
				        spdlog::error("error in decoder thread: {}", e.what());
			        }
		        }
	        });
}

decoder::~decoder()
{
	if (image_reader)
		AImageReader_setImageListener(image_reader.get(), nullptr);
	if (media_codec)
	{
		AMediaCodec_stop(media_codec.get());
		jobs.push([]() { return true; });
		if (worker.joinable())
			worker.join();
	}
	input_buffers.close();
	jobs.close();

	if (worker.joinable())
		worker.join();

	helix_remove_health(this);
	spdlog::info("decoder::~decoder");
}

void decoder::push_data(std::span<std::span<const uint8_t>> data, uint64_t frame_index, bool partial)
{
	if (current_input_buffer.data == nullptr)
		current_input_buffer = input_buffers.pop();
	else if (current_input_buffer.frame_index != frame_index)
	{
		// Reuse the input buffer, discard existing data
		current_input_buffer.data_size = 0;
	}
	current_input_buffer.frame_index = frame_index;

	for (const auto & sub_data: data)
	{
		if (current_input_buffer.data_size + sub_data.size() > current_input_buffer.capacity)
		{
			spdlog::error("data to decode is larger than decoder buffer, skipping frame");
			helix_request_recovery(this, weak_scene, stream_index, "decoder input buffer overflow", frame_index);
			return;
		}

		memcpy(current_input_buffer.data + current_input_buffer.data_size, sub_data.data(), sub_data.size());
		current_input_buffer.data_size += sub_data.size();
	}

	if (partial)
		return;

	jobs.push([=, idx = current_input_buffer.idx, data_size = current_input_buffer.data_size, mc = media_codec.get()]() {
		uint64_t timestamp = frame_index * 10'000;
		auto status = AMediaCodec_queueInputBuffer(mc, idx, 0, data_size, timestamp, 0);
		if (status != AMEDIA_OK)
		{
			spdlog::error("AMediaCodec_queueInputBuffer: MediaCodec error {}({})",
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
			helix_request_recovery(this, weak_scene, stream_index, "MediaCodec input submission failed", frame_index);
		}
		return false;
	});
	current_input_buffer = input_buffer{};
}

void decoder::frame_completed(const wivrn::from_headset::feedback & feedback, const wivrn::to_headset::video_stream_data_shard::view_info_t & view_info)
{
	if (not media_codec)
	{
		// If media_codec is not initialized, frame processing ends here
		if (auto scene = weak_scene.lock())
			scene->send_feedback(feedback);
	}

	// nothing required for decoder, mediacodec will callback when done
	frame_infos.push(frame_info{
	        .feedback = feedback,
	        .view_info = view_info,
	});
	helix_note_submitted(this, weak_scene, stream_index, feedback);

	if (helix_should_flush(this))
	{
		spdlog::warn("Helix escalating decoder recovery to MediaCodec flush on stream {}", stream_index);

		// Stop using any input buffer obtained before the flush. The network thread
		// remains blocked on the future below until the serialized codec operation
		// finishes, so it cannot queue another stale buffer in the meantime.
		current_input_buffer = input_buffer{};

		auto completion = std::make_shared<std::promise<media_status_t>>();
		auto future = completion->get_future();
		jobs.push([this, completion, mc = media_codec.get()]() {
			helix_begin_flush(this);

			auto status = AMediaCodec_flush(mc);
			if (status == AMEDIA_OK)
			{
				// Flush revokes codec buffers. Remove stale callback bookkeeping before
				// restarting async mode so newly delivered input buffers remain valid.
				input_buffers.drop_until([](auto &) { return false; });
				frame_infos.drop_until([](auto &) { return false; });
				status = AMediaCodec_start(mc);
			}

			completion->set_value(status);
			return false;
		});

		auto status = future.get();
		if (status == AMEDIA_OK)
		{
			helix_reset_after_flush(this);
			spdlog::info("Helix MediaCodec flush completed on stream {}", stream_index);
			helix_request_recovery(this, weak_scene, stream_index, "decoder flushed; fresh IDR required", feedback.frame_index);
		}
		else
		{
			spdlog::error("Helix MediaCodec flush/restart failed on stream {}: {}({})",
			              stream_index,
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
		}
	}
}

void decoder::on_image_available(void * context, AImageReader * reader)
{
	try
	{
		static_cast<decoder *>(context)->on_image_available(reader);
	}
	catch (std::exception & e)
	{
		spdlog::error("Exception in decoder::on_image_available: {}", e.what());
	}
}

void decoder::on_image_available(AImageReader * reader)
{
	assert(reader == image_reader.get());
	// Executed on image reader thread

	decltype(android_blit_handle::aimage) image;
	try
	{
		AImage * tmp;
		check(AImageReader_acquireLatestImage(image_reader.get(), &tmp), "AImageReader_acquireLatestImage");
		image.reset(tmp);

		int64_t fake_timestamp_ns;
		check(AImage_getTimestamp(image.get(), &fake_timestamp_ns), "AImage_getTimestamp");
		uint64_t frame_index = (fake_timestamp_ns + 5'000'000) / (10'000'000);

		frame_infos.drop_until([frame_index](auto & x) { return x.feedback.frame_index >= frame_index; });

		auto info = frame_infos.pop_if([frame_index](auto & x) { return x.feedback.frame_index == frame_index; });

		if (!info)
		{
			spdlog::warn("No frame info for frame {}, dropping frame", frame_index);
			return;
		}

		assert(info->feedback.frame_index == frame_index);
		helix_note_decoded(this, frame_index);

		auto vk_data = map_hardware_buffer(image.get());

		auto handle = std::make_shared<android_blit_handle>(
		        info->feedback,
		        info->view_info,
		        *vk_data->image_view,
		        *vk_data->vimage,
		        vk_data->extent,
		        vk_data->layout,
		        std::move(vk_data),
		        image_reader,
		        std::move(image));

		if (auto scene = weak_scene.lock())
			scene->push_blit_handle(accumulator, std::move(handle));
	}
	catch (const std::exception & e)
	{
		spdlog::warn("Helix image output failure on stream {}: {}", stream_index, e.what());
		helix_request_recovery(this, weak_scene, stream_index, "image output processing failed");
	}
	catch (...)
	{
		spdlog::warn("Helix unknown image output failure on stream {}", stream_index);
		helix_request_recovery(this, weak_scene, stream_index, "unknown image output processing failure");
	}
}

void decoder::create_sampler(const AHardwareBuffer_Desc & buffer_desc, vk::AndroidHardwareBufferFormatPropertiesANDROID & ahb_format)
{
	assert(ahb_format.externalFormat != 0);
	spdlog::info("AndroidHardwareBufferProperties");
	spdlog::info("  Vulkan format: {}", vk::to_string(ahb_format.format));
	spdlog::info("  External format: {:#x}", ahb_format.externalFormat);
	spdlog::info("  Format features: {}", vk::to_string(ahb_format.formatFeatures));
	spdlog::info("  samplerYcbcrConversionComponents: ({}, {}, {}, {})",
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.r),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.g),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.b),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.a));
	spdlog::info("  Suggested YCbCr model: {}", vk::to_string(ahb_format.suggestedYcbcrModel));
	spdlog::info("  Suggested YCbCr range: {}", vk::to_string(ahb_format.suggestedYcbcrRange));
	spdlog::info("  Suggested X chroma offset: {}", vk::to_string(ahb_format.suggestedXChromaOffset));
	spdlog::info("  Suggested Y chroma offset: {}", vk::to_string(ahb_format.suggestedYChromaOffset));

	vk::Filter yuv_filter;
	if (ahb_format.formatFeatures & vk::FormatFeatureFlagBits::eSampledImageYcbcrConversionLinearFilter)
		yuv_filter = vk::Filter::eLinear;
	else
		yuv_filter = vk::Filter::eNearest;

	// Create VkSamplerYcbcrConversion
	vk::StructureChain ycbcr_create_info{
	        vk::SamplerYcbcrConversionCreateInfo{
	                .format = vk::Format::eUndefined,
	                .ycbcrModel = ahb_format.suggestedYcbcrModel,
	                .ycbcrRange = ahb_format.suggestedYcbcrRange,
	                .components = ahb_format.samplerYcbcrConversionComponents,
	                .xChromaOffset = ahb_format.suggestedXChromaOffset,
	                .yChromaOffset = ahb_format.suggestedYChromaOffset,
	                .chromaFilter = yuv_filter,
	        },
	        vk::ExternalFormatANDROID{
	                .externalFormat = ahb_format.externalFormat,
	        },
	};

	// suggested values from decoder don't actually read the metadata, so it's garbage
	ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>().ycbcrRange = vk::SamplerYcbcrRange::eItuFull;
	ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>().ycbcrModel = vk::SamplerYcbcrModelConversion::eYcbcr709;

	ycbcr_conversion = vk::raii::SamplerYcbcrConversion(device, ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>());

	// Create VkSampler
	vk::StructureChain sampler_info{
	        vk::SamplerCreateInfo{
	                .magFilter = yuv_filter,
	                .minFilter = yuv_filter,
	                .mipmapMode = vk::SamplerMipmapMode::eNearest,
	                .addressModeU = vk::SamplerAddressMode::eClampToEdge,
	                .addressModeV = vk::SamplerAddressMode::eClampToEdge,
	                .addressModeW = vk::SamplerAddressMode::eClampToEdge,
	                .mipLodBias = 0.0f,
	                .anisotropyEnable = VK_FALSE,
	                .maxAnisotropy = 1,
	                .compareEnable = VK_FALSE,
	                .compareOp = vk::CompareOp::eNever,
	                .minLod = 0.0f,
	                .maxLod = 0.0f,
	                .borderColor = vk::BorderColor::eFloatOpaqueWhite, // TODO TBC
	                .unnormalizedCoordinates = VK_FALSE,
	        },
	        vk::SamplerYcbcrConversionInfo{
	                .conversion = *ycbcr_conversion,
	        },
	};

	ycbcr_sampler = vk::raii::Sampler(device, sampler_info.get());
}

std::shared_ptr<decoder::mapped_hardware_buffer> decoder::map_hardware_buffer(AImage * image)
{
	AHardwareBuffer * hardware_buffer;
	check(AImage_getHardwareBuffer(image, &hardware_buffer), "AImage_getHardwareBuffer");

	std::unique_lock lock(hbm_mutex);

	AHardwareBuffer_Desc buffer_desc{};
	AHardwareBuffer_describe(hardware_buffer, &buffer_desc);

	auto [properties, format_properties] = device.getAndroidHardwareBufferPropertiesANDROID<vk::AndroidHardwareBufferPropertiesANDROID, vk::AndroidHardwareBufferFormatPropertiesANDROID>(*hardware_buffer);

	if (!*ycbcr_sampler || memcmp(&ahb_format, &format_properties, sizeof(format_properties)))
	{
		memcpy(&ahb_format, &format_properties, sizeof(format_properties));
		spdlog::info("decoded image size: {}x{}", buffer_desc.width, buffer_desc.height);
		create_sampler(buffer_desc, ahb_format);
		hardware_buffer_map.clear();
		// TODO tell the reprojector to recreate the pipeline
	}

	auto it = hardware_buffer_map.find(hardware_buffer);
	if (it != hardware_buffer_map.end())
		return it->second;

	vk::StructureChain img_info{
	        vk::ImageCreateInfo{
	                .flags = {},
	                .imageType = vk::ImageType::e2D,
	                .format = vk::Format::eUndefined,
	                .extent = {buffer_desc.width, buffer_desc.height, 1},
	                .mipLevels = 1,
	                .arrayLayers = 1,
	                .samples = vk::SampleCountFlagBits::e1,
	                .tiling = vk::ImageTiling::eOptimal,
	                .usage = vk::ImageUsageFlagBits::eSampled,
	                .sharingMode = vk::SharingMode::eExclusive,
	                .initialLayout = vk::ImageLayout::eUndefined,
	        },
	        vk::ExternalMemoryImageCreateInfo{
	                .handleTypes = vk::ExternalMemoryHandleTypeFlagBits::eAndroidHardwareBufferANDROID,
	        },
	        vk::ExternalFormatANDROID{
	                .externalFormat = format_properties.externalFormat,
	        },
	};

	vk::raii::Image vimage(device, img_info.get());

	assert(properties.memoryTypeBits != 0);
	vk::StructureChain mem_info{
	        vk::MemoryAllocateInfo{
	                .allocationSize = properties.allocationSize,
	                .memoryTypeIndex = (uint32_t)(ffs(properties.memoryTypeBits) - 1),
	        },
	        vk::MemoryDedicatedAllocateInfo{
	                .image = *vimage,
	        },
	        vk::ImportAndroidHardwareBufferInfoANDROID{
	                .buffer = hardware_buffer,
	        },
	};

	vk::raii::DeviceMemory memory(device, mem_info.get());

	vimage.bindMemory(*memory, 0);

	vk::StructureChain iv_info{
	        vk::ImageViewCreateInfo{
	                .image = *vimage,
	                .viewType = vk::ImageViewType::e2D,
	                .format = vk::Format::eUndefined,
	                .subresourceRange = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .baseMipLevel = 0,
	                        .levelCount = 1,
	                        .baseArrayLayer = 0,
	                        .layerCount = 1,
	                },
	        },
	        vk::SamplerYcbcrConversionInfo{
	                .conversion = *ycbcr_conversion,
	        },
	};

	application::ignore_debug_reports_for(*vimage);
	vk::raii::ImageView image_view(device, iv_info.get());
	application::unignore_debug_reports_for(*vimage);

	auto handle = std::make_shared<mapped_hardware_buffer>();
	handle->vimage = std::move(vimage);
	handle->image_view = std::move(image_view);
	handle->memory = std::move(memory);
	handle->extent = vk::Extent2D{
	        .width = buffer_desc.width,
	        .height = buffer_desc.height,
	};

	hardware_buffer_map[hardware_buffer] = handle;
	return handle;
}

void decoder::on_media_error(AMediaCodec *, void * userdata, media_status_t error, int32_t actionCode, const char * detail)
{
	auto self = (decoder *)userdata;
	spdlog::warn("Mediacodec error {} action {}: {}", int(error), actionCode, detail ? detail : "unknown");
	helix_request_recovery(self, self->weak_scene, self->stream_index, "MediaCodec asynchronous error");
}
void decoder::on_media_format_changed(AMediaCodec *, void * userdata, AMediaFormat *)
{
	spdlog::info("Mediacodec format changed");
}
void decoder::on_media_input_available(AMediaCodec * media_codec, void * userdata, int32_t index)
{
	auto self = (decoder *)userdata;
	size_t size;
	uint8_t * buffer = AMediaCodec_getInputBuffer(media_codec, index, &size);
	self->input_buffers.push({
	        .idx = index,
	        .capacity = size,
	        .data = buffer,
	});
}
void decoder::on_media_output_available(AMediaCodec * media_codec, void * userdata, int32_t index, AMediaCodecBufferInfo * bufferInfo)
{
	auto self = (decoder *)userdata;
	auto generation = helix_codec_generation(self);
	self->jobs.push([=]() {
		// A flush revokes outstanding codec buffers. Ignore any release job queued by
		// an old-generation callback after the flush operation was already scheduled.
		if (!helix_codec_generation_matches(self, generation))
			return false;

		auto status = AMediaCodec_releaseOutputBuffer(media_codec, index, true);
		// will trigger on_image_available through ImageReader
		if (status != AMEDIA_OK)
		{
			spdlog::error("AMediaCodec_releaseOutputBuffer: MediaCodec error {}({})",
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
			helix_request_recovery(self, self->weak_scene, self->stream_index, "MediaCodec output release failed");
		}
		return false;
	});
}

static bool hardware_accelerated(AMediaCodec * media_codec)
{
	// MediaCodecInfo has isHardwareAccelerated, but this does not exist in NDK.
	char * name;
	AMediaCodec_getName(media_codec, &name);
	auto release = [&]() {
		AMediaCodec_releaseName(media_codec, name);
	};
	for (const char * prefix: {
	             "OMX.google",
	             "c2.android",
	     })
	{
		if (std::string_view(name).starts_with(prefix))
		{
			release();
			return false;
		}
	}
	release();
	return true;
}

void decoder::supported_codecs(std::vector<wivrn::video_codec> & result)
{
	// Make sure we update this code when codecs are changed
	static_assert(magic_enum::enum_count<wivrn::video_codec>() == 4);

	// In order or preference, from preferred to least preferred
	for (auto codec: {
	             wivrn::video_codec::av1,
	             wivrn::video_codec::h265,
	             wivrn::video_codec::h264,
	     })
	{
		AMediaCodec_ptr media_codec(AMediaCodec_createDecoderByType(mime(codec)));

		bool supported = media_codec and hardware_accelerated(media_codec.get());
		if (supported)
			result.push_back(codec);

		spdlog::info("video codec {}: {}supported", magic_enum::enum_name(codec), supported ? "" : "NOT ");
	}
}

} // namespace wivrn::android
