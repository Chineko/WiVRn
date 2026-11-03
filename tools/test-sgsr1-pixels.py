#!/usr/bin/env python3
"""Exercise the actual SGSR1 include on synthetic textures with a GLES pbuffer.

Checks DC preservation, bounded edges and effective sharpening control. This is
not a Quest visual-quality, YCbCr import or performance validation.
"""
import ctypes as c
from pathlib import Path
import numpy as np

egl=c.CDLL('libEGL.so.1')
gl=c.CDLL('libGLESv2.so.2')
def fn(lib,name,result,*args):
    f=getattr(lib,name); f.restype=result; f.argtypes=list(args); return f
ptr=c.c_void_p; integer=c.c_int; uint=c.c_uint
arr=lambda *a:(integer*len(a))(*a)
getdisplay=fn(egl,'eglGetPlatformDisplay',ptr,uint,ptr,c.POINTER(c.c_ssize_t))
display=getdisplay(0x31DD,None,None) # surfaceless
assert fn(egl,'eglInitialize',uint,ptr,ptr,ptr)(display,None,None)
assert fn(egl,'eglBindAPI',uint,uint)(0x30A0)
config=ptr(); count=integer()
assert fn(egl,'eglChooseConfig',uint,ptr,ptr,ptr,integer,ptr)(display,arr(
    0x3033,1,0x3040,0x40,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038),c.byref(config),1,c.byref(count)) and count.value
surface=fn(egl,'eglCreatePbufferSurface',ptr,ptr,ptr,ptr)(display,config,arr(0x3057,32,0x3056,32,0x3038))
context=fn(egl,'eglCreateContext',ptr,ptr,ptr,ptr,ptr)(display,config,None,arr(0x3098,3,0x3038))
assert fn(egl,'eglMakeCurrent',uint,ptr,ptr,ptr,ptr)(display,surface,surface,context)
print('Renderer:',fn(gl,'glGetString',c.c_char_p,uint)(0x1F01).decode())
def shader(kind,source):
    s=fn(gl,'glCreateShader',uint,uint)(kind)
    data=c.c_char_p(source.encode())
    fn(gl,'glShaderSource',None,uint,integer,ptr,ptr)(s,1,c.byref(data),None)
    fn(gl,'glCompileShader',None,uint)(s)
    ok=integer(); fn(gl,'glGetShaderiv',None,uint,uint,ptr)(s,0x8B81,c.byref(ok))
    if not ok.value:
        log=c.create_string_buffer(16384); fn(gl,'glGetShaderInfoLog',None,uint,integer,ptr,ptr)(s,len(log),None,log)
        raise RuntimeError(log.value.decode())
    return s
inc=(Path(__file__).resolve().parents[1]/'client/shaders/sgsr1.inc').read_text()
vibrance=(Path(__file__).resolve().parents[1]/'client/shaders/vibrance.inc').read_text()
vs=shader(0x8B31,'#version 310 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0,1);}')
fs=shader(0x8B30,'#version 310 es\nprecision highp float; precision highp int;\nuniform ivec4 rgb_rect; uniform sampler2D rgb[1]; uniform float strength; uniform float vibrance_amount; layout(location=0) out vec4 color;\n'+inc+vibrance+'\nvoid main(){color=vec4(apply_vibrance(sgsr1_filter(gl_FragCoord.xy/32.,strength),vibrance_amount),1);}')
program=fn(gl,'glCreateProgram',uint)()
attach=fn(gl,'glAttachShader',None,uint,uint)
attach(program,vs);attach(program,fs)
fn(gl,'glLinkProgram',None,uint)(program)
ok=integer(); fn(gl,'glGetProgramiv',None,uint,uint,ptr)(program,0x8B82,c.byref(ok)); assert ok.value
fn(gl,'glUseProgram',None,uint)(program)
location=lambda name:fn(gl,'glGetUniformLocation',integer,uint,c.c_char_p)(program,name.encode())
fn(gl,'glUniform4i',None,integer,integer,integer,integer,integer)(location('rgb_rect'),0,0,16,16)
fn(gl,'glUniform1i',None,integer,integer)(location('rgb[0]'),0)
texture=uint(); fn(gl,'glGenTextures',None,integer,ptr)(1,c.byref(texture))
fn(gl,'glBindTexture',None,uint,uint)(0x0DE1,texture)
for key,value in ((0x2801,0x2601),(0x2800,0x2601),(0x2802,0x812F),(0x2803,0x812F)):
    fn(gl,'glTexParameteri',None,uint,uint,integer)(0x0DE1,key,value)
fn(gl,'glViewport',None,integer,integer,integer,integer)(0,0,32,32)
def render(image,strength,vibrance_amount=0.):
    fn(gl,'glTexImage2D',None,uint,integer,integer,integer,integer,integer,uint,uint,ptr)(0x0DE1,0,0x8058,16,16,0,0x1908,0x1401,image.ctypes.data)
    fn(gl,'glUniform1f',None,integer,c.c_float)(location('strength'),strength)
    fn(gl,'glUniform1f',None,integer,c.c_float)(location('vibrance_amount'),vibrance_amount)
    fn(gl,'glDrawArrays',None,uint,integer,integer)(4,0,3)
    output=np.empty((32,32,4),dtype=np.uint8)
    fn(gl,'glReadPixels',None,integer,integer,integer,integer,uint,uint,ptr)(0,0,32,32,0x1908,0x1401,output.ctypes.data)
    assert fn(gl,'glGetError',uint)()==0
    return output
flat=np.full((16,16,4),128,dtype=np.uint8);flat[:,:,3]=255
for strength in (1.,1.75,2.):
    out=render(flat,strength)
    assert np.max(np.abs(out[:,:,:3].astype(int)-128))<=1, 'DC/texture boundary corruption'
    assert np.all(out[:,:,3]==255)
y,x=np.indices((16,16)); edge=flat.copy()
edge[:,:,:3]=np.where((x+y)[:,:,None]>=15,190,60)
low=render(edge,1.);middle=render(edge,1.75);high=render(edge,2.)
assert not np.array_equal(low,middle), 'slider has no effect'
assert not np.array_equal(low,high), 'sharpness endpoints equal'
assert np.all((high[:,:,:3]>=35)&(high[:,:,:3]<=215)), 'edge overshoot'
print('PASS: constant image/eye borders preserved; slider changes diagonal-edge reconstruction; bounded output')
for level in (0,32,128,224,255):
    gray=np.full((16,16,4),level,dtype=np.uint8);gray[:,:,3]=255
    assert np.max(np.abs(render(gray,1.75,1.)[:,:,:3].astype(int)-level))<=1
muted=flat.copy();muted[:,:,:3]=[130,100,90]
unchanged=render(muted,1.75,0.)[16,16,:3].astype(float)
boosted=render(muted,1.75,1.)[16,16,:3].astype(float)
assert np.max(np.abs(unchanged-[130,100,90]))<=1, '0% must preserve color'
assert np.ptp(boosted)>np.ptp(unchanged), 'muted colors not boosted'
assert abs(np.dot(boosted-unchanged,[.2126,.7152,.0722]))<1.5, 'luma changed'
for color in ([255,0,0],[0,255,0],[0,0,255],[1,2,3],[253,254,255]):
    image=flat.copy();image[:,:,:3]=color
    assert np.max(np.abs(render(image,1.75,1.)[:,:,:3].astype(int)-color))<=5
print('PASS: vibrance preserves grays/0%, boosts muted chroma, bounds gamut and preserves luma')
fn(egl,'eglMakeCurrent',uint,ptr,ptr,ptr,ptr)(display,None,None,None)
fn(egl,'eglDestroyContext',uint,ptr,ptr)(display,context)
fn(egl,'eglDestroySurface',uint,ptr,ptr)(display,surface)
fn(egl,'eglTerminate',uint,ptr)(display)
