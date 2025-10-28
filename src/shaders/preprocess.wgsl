const SH_C0: f32 = 0.28209479177387814;
const SH_C1 = 0.4886025119029199;
const SH_C2 = array<f32,5>(
    1.0925484305920792,
    -1.0925484305920792,
    0.31539156525252005,
    -1.0925484305920792,
    0.5462742152960396
);
const SH_C3 = array<f32,7>(
    -0.5900435899266435,
    2.890611442640554,
    -0.4570457994644658,
    0.3731763325901154,
    -0.4570457994644658,
    1.445305721320277,
    -0.5900435899266435
);

override workgroupSize: u32;
override sortKeyPerThread: u32;

struct DispatchIndirect {
    dispatch_x: atomic<u32>,
    dispatch_y: u32,
    dispatch_z: u32,
}

struct SortInfos {
    keys_size: atomic<u32>,  // instance_count in DrawIndirect
    //data below is for info inside radix sort 
    padded_size: u32, 
    passes: u32,
    even_pass: u32,
    odd_pass: u32,
}

struct CameraUniforms {
    view: mat4x4<f32>,
    view_inv: mat4x4<f32>,
    proj: mat4x4<f32>,
    proj_inv: mat4x4<f32>,
    viewport: vec2<f32>,
    focal: vec2<f32>
};

struct RenderSettings {
    gaussian_scaling: f32,
    sh_deg: f32,
}

struct Gaussian {
    pos_opacity: array<u32,2>,
    rot: array<u32,2>,
    scale: array<u32,2>
};

struct Splat {
    //TODO: store information for 2D splat rendering
    radius: f32,
    opacity: f32,
    uv: vec2f,
    conic: mat2x2f,
    color: vec3f,
    culled: u32,
};

//TODO: bind your data here
@group(0) @binding(0)
var<storage, read_write> sort_infos: SortInfos;
@group(0) @binding(1)
var<storage, read_write> sort_depths : array<u32>;
@group(0) @binding(2)
var<storage, read_write> sort_indices : array<u32>;
@group(0) @binding(3)
var<storage, read_write> sort_dispatch: DispatchIndirect;

@group(1) @binding(0)
var<storage,read> gaussians: array<Gaussian>;
@group(1) @binding(1)
var<storage, read_write> splats: array<Splat>;
@group(1) @binding(2)
var<storage, read> sphericalHarmonicCoeffs: array<u32>;

@group(2) @binding(0)
var<uniform> gaussianMultiplier: f32;

@group(3) @binding(0)
var<uniform> cameraUniforms: CameraUniforms;

/// reads the ith sh coef from the storage buffer 
fn sh_coef(splat_idx: u32, c_idx: u32) -> vec3<f32> {
    //TODO: access your binded sh_coeff, see load.ts for how it is stored
    let coeffsIndex = ((splat_idx * 16 + c_idx) * 3);
    let vals0 = unpack2x16float(sphericalHarmonicCoeffs[coeffsIndex / 2]);
    let vals1 = unpack2x16float(sphericalHarmonicCoeffs[coeffsIndex / 2 + 1]);
    
    if (coeffsIndex & 1u) == 0u {
        return vec3f(vals0.x, vals0.y, vals1.x);
    } else {
        return vec3f(vals0.y, vals1.x, vals1.y);
    }
}

// spherical harmonics evaluation with Condon–Shortley phase
fn computeColorFromSH(dir: vec3<f32>, v_idx: u32, sh_deg: u32) -> vec3<f32> {
    var result = SH_C0 * sh_coef(v_idx, 0u);

    if sh_deg > 0u {

        let x = dir.x;
        let y = dir.y;
        let z = dir.z;

        result += - SH_C1 * y * sh_coef(v_idx, 1u) + SH_C1 * z * sh_coef(v_idx, 2u) - SH_C1 * x * sh_coef(v_idx, 3u);

        if sh_deg > 1u {

            let xx = dir.x * dir.x;
            let yy = dir.y * dir.y;
            let zz = dir.z * dir.z;
            let xy = dir.x * dir.y;
            let yz = dir.y * dir.z;
            let xz = dir.x * dir.z;

            result += SH_C2[0] * xy * sh_coef(v_idx, 4u) + SH_C2[1] * yz * sh_coef(v_idx, 5u) + SH_C2[2] * (2.0 * zz - xx - yy) * sh_coef(v_idx, 6u) + SH_C2[3] * xz * sh_coef(v_idx, 7u) + SH_C2[4] * (xx - yy) * sh_coef(v_idx, 8u);

            if sh_deg > 2u {
                result += SH_C3[0] * y * (3.0 * xx - yy) * sh_coef(v_idx, 9u) + SH_C3[1] * xy * z * sh_coef(v_idx, 10u) + SH_C3[2] * y * (4.0 * zz - xx - yy) * sh_coef(v_idx, 11u) + SH_C3[3] * z * (2.0 * zz - 3.0 * xx - 3.0 * yy) * sh_coef(v_idx, 12u) + SH_C3[4] * x * (4.0 * zz - xx - yy) * sh_coef(v_idx, 13u) + SH_C3[5] * z * (xx - yy) * sh_coef(v_idx, 14u) + SH_C3[6] * x * (xx - 3.0 * yy) * sh_coef(v_idx, 15u);
            }
        }
    }
    result += 0.5;

    return  max(vec3<f32>(0.), result);
}

@compute @workgroup_size(workgroupSize,1,1)
fn preprocess(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) wgs: vec3<u32>) {
    let idx = gid.x;
    if idx >= arrayLength(&gaussians) { return; }

    //TODO: set up pipeline as described in instruction

    let keys_per_dispatch = workgroupSize * sortKeyPerThread; 
    // increment DispatchIndirect.dispatchx each time you reach limit for one dispatch of keys

    let gaussian = gaussians[idx];

    let a = unpack2x16float(gaussian.pos_opacity[0]);
    let b = unpack2x16float(gaussian.pos_opacity[1]);
    let pos = vec3f(a.x, a.y, b.x);
    let opacity = 1 / (1 + exp(-b.y));

    let rot0 = unpack2x16float(gaussian.rot[0]);
    let rot1 = unpack2x16float(gaussian.rot[1]);
    let quat = vec4(rot0.x, rot0.y, rot1.x, rot1.y);
    let rotMat = mat3x3f(
        1 - 2 * (quat.z * quat.z + quat.w * quat.w), 2 * (quat.y * quat.z - quat.x * quat.w), 2 * (quat.y * quat.w + quat.x * quat.z),
        2 * (quat.y * quat.z + quat.x * quat.w), 1 - 2 * (quat.y * quat.y + quat.w * quat.w), 2 * (quat.z * quat.w - quat.x * quat.y),
        2 * (quat.y * quat.w - quat.x * quat.z), 2 * (quat.z * quat.w + quat.x * quat.y), 1 - 2 * (quat.y * quat.y + quat.z * quat.z),
    );

    let scale0 = unpack2x16float(gaussian.scale[0]);
    let scale1 = unpack2x16float(gaussian.scale[1]);
    let scale = vec3f(exp(scale0.x), exp(scale0.y), exp(scale1.x));
    let scaleMat = mat3x3f(
        scale.x, 0, 0,
        0, scale.y, 0,
        0, 0, scale.z,
    ) * gaussianMultiplier;

    let transformMat = rotMat * scaleMat;
    let cov3 = transformMat * transpose(transformMat);

    let viewPos = (cameraUniforms.view * vec4f(pos, 1)).xyz;
    
    let w = mat3x3f(
        cameraUniforms.view[0].xyz,
        cameraUniforms.view[1].xyz,
        cameraUniforms.view[2].xyz,
    );
    
    let tanFov = cameraUniforms.viewport / cameraUniforms.focal / 2 * 1.2;
    
    let z2 = viewPos.z * viewPos.z;
    let j = mat3x3f(
        cameraUniforms.focal.x / viewPos.z, 0, -cameraUniforms.focal.x * viewPos.x / z2,
        0, cameraUniforms.focal.y / viewPos.z, -cameraUniforms.focal.y * viewPos.y / z2,
        0, 0, 0,
    );
    
    let t = j * w;
    let vrk = mat3x3f(
        cov3[0][0], cov3[0][1], cov3[0][2],
        cov3[0][1], cov3[1][1], cov3[1][2],
        cov3[0][2], cov3[1][2], cov3[2][2],
    );
    
    let cov2_3 = transpose(t) * transpose(vrk) * t;
    
    let cov2 = mat2x2(
        cov2_3[0][0] + 0.3, cov2_3[0][1],
        cov2_3[0][1], cov2_3[1][1] + 0.3,
    );
    
    let det = determinant(cov2);
    let conic = mat2x2(
        cov2[1][1], -cov2[1][0],
        -cov2[0][1], cov2[0][0],
    ) * (1 / det);
    
    let mid = 0.5 * (cov2[0][0] + cov2[1][1]);
    let mid2 = mid * mid;
    let eigen1 = mid + sqrt(max(0.1, mid2 - det));
    let eigen2 = mid - sqrt(max(0.1, mid2 - det));
    let maxEigen = max(eigen1, eigen2);
    let radius = ceil(3 * sqrt(maxEigen));
    
    const MARGIN = 0.2;
    
    let projViewPosHom = cameraUniforms.proj * vec4f(viewPos, 1);
    if projViewPosHom.w < 0 {
        splats[idx].culled = 1;
        return;
    }
    let projViewPos = projViewPosHom.xyz / projViewPosHom.w;
    let uv = vec2f(
        (projViewPos.x * 0.5 + 0.5) * cameraUniforms.viewport.x,
        (1 - (projViewPos.y * 0.5 + 0.5)) * cameraUniforms.viewport.y,
    );
    
    if uv.x + radius < -cameraUniforms.viewport.x * MARGIN || uv.x - radius > cameraUniforms.viewport.x * (1 + MARGIN)
       || uv.y + radius < -cameraUniforms.viewport.y * MARGIN || uv.y - radius > cameraUniforms.viewport.y * (1 + MARGIN) {
        splats[idx].culled = 1;
        return;
    }
    
    let cameraDir = normalize(pos - cameraUniforms.view_inv[3].xyz);
    let color = computeColorFromSH(cameraDir, idx, 3);
    
    
    splats[idx].radius = radius;
    splats[idx].opacity = opacity;
    splats[idx].uv = uv;
    splats[idx].conic = conic;
    splats[idx].color = color;
    splats[idx].culled = 0;
}