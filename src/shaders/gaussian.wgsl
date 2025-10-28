struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

struct Gaussian {
    pos_opacity: array<u32,2>,
    rot: array<u32,2>,
    scale: array<u32,2>
}

struct Splat {
    //TODO: information defined in preprocess compute shader
    radius: f32,
    opacity: f32,
    uv: vec2f,
    conic: mat2x2f,
    color: vec3f,
}

@group(0) @binding(0)
var<uniform> camera: CameraUniforms;

@group(1) @binding(0)
var<storage,read> gaussians : array<Gaussian>;

@group(1) @binding(1)
var<storage, read> splats: array<Splat>;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    //TODO: information passed from vertex shader to fragment shader
    @location(0) color: vec3f,
    @location(1) radius: f32,
    @location(2) conicUpperTriangle: vec3f,
    @location(3) opacity: f32,
    @location(4) uv: vec2f,
};

const quadOffsets = array(
    vec2f(-1, -1),
    vec2f(-1, 1),
    vec2f(1, -1),
    vec2f(1, -1),
    vec2f(-1, 1),
    vec2f(1, 1),
);

@vertex
fn vs_main(
    @builtin(vertex_index) in_vertex_index: u32,
    @builtin(instance_index) in_instance_index: u32,
) -> VertexOutput {
    //TODO: reconstruct 2D quad based on information from splat, pass 
    var out: VertexOutput;

    let vertex = gaussians[in_instance_index];
    let splat = splats[in_instance_index];

    var uvNormalized = (splat.uv + quadOffsets[in_vertex_index] * splat.radius) / camera.viewport * 2 - 1;
    uvNormalized.y *= -1;

    out.position = vec4(uvNormalized, 0, 1);
    out.radius = splat.radius;
    out.color = splat.color;
    out.conicUpperTriangle = vec3f(splat.conic[0][0], splat.conic[0][1], splat.conic[1][1]);
    out.opacity = splat.opacity;
    out.uv = splat.uv;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let posDiff = (in.position.xy - in.uv);
    let conic = mat2x2f(in.conicUpperTriangle.x, in.conicUpperTriangle.y, in.conicUpperTriangle.y, in.conicUpperTriangle.z);
    let alpha = in.opacity * exp(-dot(posDiff, conic * posDiff) / 2);
    
    return vec4f(in.color, alpha);
}