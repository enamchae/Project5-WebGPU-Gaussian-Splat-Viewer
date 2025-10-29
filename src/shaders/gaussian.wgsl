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
    radiusOpacity: u32,
    uvNormalized: u32,
    conicXy: u32,
    conicZ: f32,
    color: vec3f,
    culled: u32,
}

@group(0) @binding(0)
var<uniform> camera: CameraUniforms;

@group(1) @binding(0)
var<storage,read> gaussians : array<Gaussian>;

@group(1) @binding(1)
var<storage, read> splats: array<Splat>;

@group(1) @binding(2)
var<storage, read> sortIndices: array<u32>;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    //TODO: information passed from vertex shader to fragment shader
    @location(0) color: vec3f,
    @location(1) radius: f32,
    @location(2) conicUpperTriangle: vec3f,
    @location(3) opacity: f32,
    @location(4) splatCenterScreenPos: vec2f,
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

    let sortIndex = sortIndices[in_instance_index];

    let splat = splats[sortIndex];
    if splat.culled == 1 {
        out.position = vec4(0, 0, -1, 0);
        return out;
    }

    let radiusOpacity = unpack2x16float(splat.radiusOpacity);
    let uvNormalized = unpack2x16float(splat.uvNormalized);
    let conicXy = unpack2x16float(splat.conicXy);

    let screenPos = (uvNormalized * 0.5 + 0.5) * camera.viewport;
    let offsetUv = uvNormalized + quadOffsets[in_vertex_index] * radiusOpacity.x / (camera.viewport * 0.5);

    out.position = vec4(offsetUv, 0, 1);
    out.radius = radiusOpacity.x;
    out.color = splat.color;
    out.conicUpperTriangle = vec3f(conicXy.x, conicXy.y, splat.conicZ);
    out.opacity = radiusOpacity.y;
    out.splatCenterScreenPos = screenPos;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let posDiff = vec2f(in.position.x, camera.viewport.y - in.position.y) - in.splatCenterScreenPos;
    // return vec4(in.color, 1);
    // return vec4(posDiff, 0, 1);
    let power = -0.5 * (in.conicUpperTriangle.x * posDiff.x * posDiff.x + in.conicUpperTriangle.z * posDiff.y * posDiff.y) + in.conicUpperTriangle.y * posDiff.x * posDiff.y;
    if power > 0 { discard; }
    
    let alpha = min(0.99, in.opacity * exp(power));
    if alpha < 1. / 255. { discard; }
    return vec4f(in.color * alpha, alpha);
}