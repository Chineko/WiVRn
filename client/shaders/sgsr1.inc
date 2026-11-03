// Adapted from Qualcomm SGSR1 at d926f074bcb9d714e179f1ce0fcb9ee2eeb5074e.
// Copyright (c) 2025, Qualcomm Innovation Center, Inc. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause (see sgsr1.LICENSE).
// RGBA mode uses green as the edge guide. Explicit centered samples replace
// gather because Vulkan sampler YCbCr conversion forbids OpImageGather.
// Reconstruct in the packed source grid during existing defoveation, before
// sRGB conversion/dimming. Each color decoder contains one eye; clamp taps.
vec4 sgsr1_sample(vec2 uv)
{
    vec2 half_pixel = 0.5 / vec2(rgb_rect.zw);
    return texture(rgb[0], clamp(uv, half_pixel, vec2(1.0) - half_pixel));
}
vec4 sgsr1_gather(vec2 uv, int component)
{
    vec2 size = vec2(rgb_rect.zw);
    vec2 base = (floor(uv * size - 0.5) + 0.5) / size;
    vec2 step_uv = 1.0 / size;
    // GLSL gather ordering: (0,1), (1,1), (1,0), (0,0).
    return vec4(sgsr1_sample(base + vec2(0, step_uv.y))[component],
                sgsr1_sample(base + step_uv)[component],
                sgsr1_sample(base + vec2(step_uv.x, 0))[component],
                sgsr1_sample(base)[component]);
}
float fastLanczos2(float x)
{
	float wA = x-4.0;
	float wB = x*wA-wA;
	wA *= wA;
	return wB*wA;
}
vec2 weightY(float dx, float dy,float c, float std)
{
	float x = ((dx*dx)+(dy* dy))* 0.55 + clamp(abs(c)*std, 0.0, 1.0);
	float w = fastLanczos2(x);
	return vec2(w, w * c);	
}

vec3 sgsr1_filter(vec2 uv, float sharpness)
{
	int mode = 1;
	float edgeThreshold = (4.0 / 255.0);
	float edgeSharpness = clamp(sharpness, 1.0, 2.0);

	vec4 color;
	if(mode == 1)
		color.xyz = sgsr1_sample(uv).xyz;
	else
		color.xyzw = sgsr1_sample(uv).xyzw;

	float xCenter;
	xCenter = abs(uv.x+-0.5);
	float yCenter;
	yCenter = abs(uv.y+-0.5);

	//todo: config the SR region based on needs
	//if ( mode!=4 && xCenter*xCenter+yCenter*yCenter<=0.4 * 0.4)
	if ( mode!=4)
	{
		vec2 imgCoord = ((uv*vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).zw)+vec2(-0.5,0.5));
		vec2 imgCoordPixel = floor(imgCoord);
		vec2 coord = (imgCoordPixel*vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).xy);
		vec2 pl = (imgCoord+(-imgCoordPixel));
		vec4  left = sgsr1_gather(coord, mode);

		float edgeVote = abs(left.z - left.y) + abs(color[mode] - left.y)  + abs(color[mode] - left.z) ;
		if(edgeVote > edgeThreshold)
		{
			coord.x += vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).x;

			vec4 right = sgsr1_gather(coord + vec2(vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).x, 0.0), mode);
			vec4 upDown;
			upDown.xy = sgsr1_gather(coord + vec2(0.0, -vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).y),mode).wz;
			upDown.zw  = sgsr1_gather(coord+ vec2(0.0, vec4(1.0 / vec2(rgb_rect.zw), vec2(rgb_rect.zw)).y), mode).yx;

			float mean = (left.y+left.z+right.x+right.w)*0.25;
			left = left - vec4(mean);
			right = right - vec4(mean);
			upDown = upDown - vec4(mean);
			color.w =color[mode] - mean;

			float sum = (((((abs(left.x)+abs(left.y))+abs(left.z))+abs(left.w))+(((abs(right.x)+abs(right.y))+abs(right.z))+abs(right.w)))+(((abs(upDown.x)+abs(upDown.y))+abs(upDown.z))+abs(upDown.w)));				
			float std = 2.181818/max(sum, 1e-6);
			
			vec2 aWY = weightY(pl.x, pl.y+1.0, upDown.x,std);				
			aWY += weightY(pl.x-1.0, pl.y+1.0, upDown.y,std);
			aWY += weightY(pl.x-1.0, pl.y-2.0, upDown.z,std);
			aWY += weightY(pl.x, pl.y-2.0, upDown.w,std);			
			aWY += weightY(pl.x+1.0, pl.y-1.0, left.x,std);
			aWY += weightY(pl.x, pl.y-1.0, left.y,std);
			aWY += weightY(pl.x, pl.y, left.z,std);
			aWY += weightY(pl.x+1.0, pl.y, left.w,std);
			aWY += weightY(pl.x-1.0, pl.y-1.0, right.x,std);
			aWY += weightY(pl.x-2.0, pl.y-1.0, right.y,std);
			aWY += weightY(pl.x-2.0, pl.y, right.z,std);
			aWY += weightY(pl.x-1.0, pl.y, right.w,std);

			float finalY = abs(aWY.x) > 1e-6 ? aWY.y/aWY.x : color.w;

			float maxY = max(max(left.y,left.z),max(right.x,right.w));
			float minY = min(min(left.y,left.z),min(right.x,right.w));
			finalY = clamp(edgeSharpness*finalY, minY, maxY);
					
			float deltaY = finalY -color.w;	
			
			//smooth high contrast input
			deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);

			color.x = clamp((color.x+deltaY),0.0,1.0);
			color.y = clamp((color.y+deltaY),0.0,1.0);
			color.z = clamp((color.z+deltaY),0.0,1.0);
		}
	}

	color.w = 1.0;  //assume alpha channel is not used
	return color.rgb;
}