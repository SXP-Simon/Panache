//! 2026-10-15：Dart LaTeX 转换后的理工科结构文本，用于真实渲染与可复查图集。
use handwriting_core::{FontBook, Limits, Parameters, RenderRequest};
use std::path::Path;

pub const CASES: [(&str, &str, &str); 24] = [
    (
        "calculus",
        "derivative",
        "f′(x) = lim_(h→0) (f(x+h)-f(x))/(h)",
    ),
    ("calculus", "integral", "∫₀¹ x² dx = (1)/(3)"),
    ("calculus", "series", "eˣ = ∑_(n=0)^(∞) (xⁿ)/(n!)"),
    ("calculus", "gradient", "∇f = ((∂f)/(∂x), (∂f)/(∂y))"),
    (
        "linear_algebra",
        "matrix",
        "A = [ a b ; c d ]
det(A) = ad-bc",
    ),
    (
        "linear_algebra",
        "eigenvector",
        "A(v)⃗ = λ(v)⃗, det(A-λI) = 0",
    ),
    ("linear_algebra", "norm", "‖(v)⃗‖ = √(v₁²+v₂²+v₃²)"),
    (
        "linear_algebra",
        "projection",
        "proj_(u)(v) = ((u·v)/(u·u))u",
    ),
    ("probability", "bayes", "P(A|B) = (P(B|A)P(A))/(P(B))"),
    (
        "probability",
        "normal",
        "p(x) = (1)/(σ√(2π)) e^(-((x-μ)²)/(2σ²))",
    ),
    ("probability", "variance", "Var(X) = E(X²)-E(X)²"),
    ("probability", "binomial", "P(X=k) = C_(n)^(k)pᵏ(1-p)^(n-k)"),
    ("mechanics_em", "newton", "(F)⃗ = m(a)⃗ = m(d²(r)⃗)/(dt²)"),
    ("mechanics_em", "energy", "E = ½mv² + mgh"),
    ("mechanics_em", "coulomb", "F = (1)/(4πε₀) (q₁q₂)/(r²)"),
    (
        "mechanics_em",
        "maxwell",
        "∇·(E)⃗ = (ρ)/(ε₀)
∇×(E)⃗ = -(∂(B)⃗)/(∂t)",
    ),
    ("signals", "fourier", "X(ω) = ∫_(-∞)^(∞) x(t)e^(-jωt) dt"),
    ("signals", "convolution", "y(t) = ∫_(-∞)^(∞) x(τ)h(t-τ)dτ"),
    ("signals", "sampling", "fₛ ≥ 2f_(max), Tₛ = (1)/(fₛ)"),
    ("signals", "transfer", "H(s) = (ω₀²)/(s²+2ζω₀s+ω₀²)"),
    ("chemistry", "water", "2H₂ + O₂ → 2H₂O"),
    ("chemistry", "ionic", "Ca²⁺ + CO₃²⁻ → CaCO₃↓"),
    (
        "chemistry",
        "equilibrium",
        "K = ([C]^(c)[D]^(d))/([A]^(a)[B]^(b))",
    ),
    (
        "chemistry",
        "structure_text",
        "CH₃-CH₂-OH
O=C=O
ΔG = ΔH-TΔS",
    ),
];

pub fn fonts(directory: &Path) -> FontBook {
    FontBook::new(
        &std::fs::read(directory.join("云烟体.ttf")).unwrap(),
        &[std::fs::read(directory.join("霞鹜文楷.ttf")).unwrap()],
    )
    .unwrap()
}

pub fn request(text: &str, fonts: &FontBook, size: f32, width: u32, grid: bool) -> RenderRequest {
    RenderRequest {
        text: text.into(),
        fonts: fonts.clone(),
        background: None,
        limits: Limits::default(),
        params: Parameters {
            font_size: size,
            line_spacing: size * 1.2,
            word_spacing: 0.,
            width: Some(width),
            height: Some(360),
            left_margin: 18.,
            right_margin: 18.,
            top_margin: 18.,
            bottom_margin: 18.,
            font_size_sigma: 0.,
            line_spacing_sigma: 0.,
            word_spacing_sigma: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            grid_layout: grid,
            preview: false,
            seed: 20261015,
            ..Parameters::default()
        },
    }
}
