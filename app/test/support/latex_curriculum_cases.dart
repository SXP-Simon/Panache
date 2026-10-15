/// Hand-authored scientific and engineering examples, shared by exact text
/// conversion tests and real-engine integration tests. Each entry contains
/// (curriculum topic, LaTeX source, mathematically equivalent plain notation).
const latexCurriculumCases = <String, List<(String, String, String)>>{
  '高等数学': [
    ('定积分与幂次', r'$\int_0^1 x^2 dx=\frac{1}{3}$', '∫₀¹x²dx=⅓'),
    ('偏导数', r'$\frac{\partial f}{\partial x}=2x$', '(∂f)/(∂x)=2x'),
    ('梯度', r'$\nabla f=(2x,2y)$', '∇f=(2x,2y)'),
    ('三角恒等式', r'$\sin^2 x+\cos^2 x=1$', 'sin²x+cos²x=1'),
    ('无穷极限', r'$\lim_{n\to\infty}\frac{1}{n}=0$', 'lim_(n→∞)(1)/(n)=0'),
    ('泰勒系数', r'$a_n=\frac{f^{(n)}(0)}{n!}$', 'aₙ=(f⁽ⁿ⁾(0))/(n!)'),
  ],
  '线性代数': [
    ('特征值方程', r'$A\mathbf{x}=\lambda\mathbf{x}$', 'Ax=λx'),
    ('逆矩阵', r'$A^{-1}A=I$', 'A⁻¹A=I'),
    ('转置', r'$(AB)^T=B^TA^T$', '(AB)^(T)=B^(T)A^(T)'),
    ('秩的上界', r'$\operatorname{rank}(A)\leq\min(m,n)$', 'rank(A)≤min(m,n)'),
    ('内积', r'$\langle x,y\rangle=\sum_{i=1}^n x_i y_i$', '⟨x,y⟩=∑ᵢ₌₁ⁿxᵢyᵢ'),
    ('二维矩阵', r'$A=\begin{pmatrix}1&2\\3&4\end{pmatrix}$', 'A=( 1  2 ; 3  4 )'),
  ],
  '概率与统计': [
    ('条件概率', r'$P(A\mid B)=\frac{P(A\cap B)}{P(B)}$', 'P(A|B)=(P(A∩B))/(P(B))'),
    (
      '期望线性性',
      r'$\mathbb{E}[X+Y]=\mathbb{E}[X]+\mathbb{E}[Y]$',
      '𝔼[X+Y]=𝔼[X]+𝔼[Y]',
    ),
    ('分布函数', r'$F_X(x)=P(X\leq x)$', 'F_(X)(x)=P(X≤x)'),
    ('标准化', r'$Z=\frac{X-\mu}{\sigma}$', 'Z=(X-μ)/(σ)'),
    ('二项系数', r'$\binom{n}{k}=\frac{n!}{k!(n-k)!}$', 'C(n, k)=(n!)/(k!(n-k)!)'),
    ('独立事件', r'$P(A\cap B)=P(A)P(B)$', 'P(A∩B)=P(A)P(B)'),
  ],
  '复变函数': [
    ('欧拉公式', r'$e^{i\theta}=\cos\theta+i\sin\theta$', 'e^(iθ)=cosθ+isinθ'),
    ('虚数单位', r'$i^2=-1$', 'i²=-1'),
    ('共轭', r'$z+\bar z=2\operatorname{Re}z$', 'z+z̄=2Rez'),
    ('复数域', r'$z\in\mathbb{C}$', 'z∈ℂ'),
    ('复积分闭路符号', r'$\oint_C f(z)dz=0$', '∮_(C)f(z)dz=0'),
    ('留数因子', r'$2\pi i\operatorname{Res}(f,a)$', '2πiRes(f,a)'),
  ],
  '大学物理': [
    ('质能关系', r'$E=mc^2$', 'E=mc²'),
    ('牛顿第二定律', r'$\vec F=m\vec a$', 'F⃗=ma⃗'),
    ('洛伦兹力', r'$\vec F=q\vec E+q\vec v\times\vec B$', 'F⃗=qE⃗+qv⃗×B⃗'),
    ('角动量叉乘', r'$\vec L=\vec r\times\vec p$', 'L⃗=r⃗×p⃗'),
    ('能量量子', r'$E=\hbar\omega$', 'E=ℏω'),
    ('量子态bra', r'$\bra{\psi}$', '⟨ψ|'),
    ('量子态ket', r'$\ket{\phi}$', '|ϕ⟩'),
    ('散度定律', r'$\nabla\cdot\vec B=0$', '∇·B⃗=0'),
  ],
  '电路与信号': [
    ('欧姆定律', r'$U=IR$', 'U=IR'),
    ('电容电流', r'$i=C\frac{du}{dt}$', 'i=C(du)/(dt)'),
    ('电感电压', r'$u=L\frac{di}{dt}$', 'u=L(di)/(dt)'),
    ('阻抗', r'$Z=R+j\omega L$', 'Z=R+jωL'),
    ('角频率', r'$\omega=2\pi f$', 'ω=2πf'),
    ('卷积', r'$y(t)=x(t)\ast h(t)$', 'y(t)=x(t)*h(t)'),
  ],
  '普通化学': [
    (
      '配平反应式',
      r'$2\mathrm{H}_2+\mathrm{O}_2\rightarrow2\mathrm{H}_2\mathrm{O}$',
      '2H₂+O₂→2H₂O',
    ),
    (
      '离子电荷',
      r'$\mathrm{Na}^{+}+\mathrm{Cl}^{-}\rightarrow\mathrm{NaCl}$',
      'Na⁺+Cl⁻→NaCl',
    ),
    ('硫酸根', r'$\mathrm{SO}_4^{2-}$', 'SO₄²⁻'),
    (
      '平衡箭头',
      r'$\mathrm{N}_2+3\mathrm{H}_2\rightleftharpoons2\mathrm{NH}_3$',
      'N₂+3H₂⇌2NH₃',
    ),
    ('反应自由能', r'$\Delta G=\Delta H-T\Delta S$', 'ΔG=ΔH-TΔS'),
    ('化学势', r'$\mu=\mu_0+RT\ln a$', 'μ=μ₀+RTlna'),
  ],
  '离散数学': [
    ('命题等价', r'$p\Rightarrow q\equiv\neg p\lor q$', 'p⇒q≡¬p∨q'),
    ('量词', r'$\forall x\in A,\exists y\in B:xRy$', '∀x∈A,∃y∈B:xRy'),
    ('集合关系', r'$A\subseteq B\iff A\cap B=A$', 'A⊆B ⇔ A∩B=A'),
    ('空集', r'$A\cap\varnothing=\varnothing$', 'A∩∅=∅'),
    ('笛卡尔积', r'$A\times B=\{(a,b):a\in A,b\in B\}$', 'A×B={(a,b):a∈A,b∈B}'),
    ('整除与同余', r'$a\equiv b\pmod n$', 'a≡b (mod n)'),
  ],

  '微分方程与PDE': [
    ('一阶常微分方程', r'$\frac{dy}{dx}=ky$', '(dy)/(dx)=ky'),
    (
      '阻尼振子',
      r'$\ddot x+2\zeta\omega_0\dot x+\omega_0^2x=0$',
      'ẍ+2ζω₀ẋ+ω₀²x=0',
    ),
    (
      '热传导方程',
      r'$\frac{\partial u}{\partial t}=\alpha\nabla^2u$',
      '(∂u)/(∂t)=α∇²u',
    ),
  ],
  '向量分析与积分定理': [
    (
      'Gauss散度定理',
      r'$\oiint_{\partial V}\vec F\cdot d\vec S=\iiint_V\nabla\cdot\vec FdV$',
      '∯_(∂V)F⃗·dS⃗=∭_(V)∇·F⃗dV',
    ),
    (
      'Stokes旋度定理',
      r'$\oint_{\partial S}\vec A\cdot d\vec l=\iint_S(\nabla\times\vec A)\cdot d\vec S$',
      '∮_(∂S)A⃗·dl⃗=∬_(S)(∇×A⃗)·dS⃗',
    ),
    (
      'Green公式',
      r'$\oint_C Pdx+Qdy=\iint_D(\frac{\partial Q}{\partial x}-\frac{\partial P}{\partial y})dxdy$',
      '∮_(C)Pdx+Qdy=∬_(D)((∂Q)/(∂x)-(∂P)/(∂y))dxdy',
    ),
  ],
  '热力学': [
    ('理想气体方程', r'$PV=nRT$', 'PV=nRT'),
    ('热力学第一定律', r'$\Delta U=Q-W$', 'ΔU=Q-W'),
    ('可逆热量与熵', r'$dS=\frac{\delta Q_{\mathrm{rev}}}{T}$', 'dS=(δQᵣₑᵥ)/(T)'),
    ('Carnot效率', r'$\eta=1-\frac{T_c}{T_h}$', 'η=1-(T_(c))/(Tₕ)'),
  ],
  '光学与波动': [
    ('Snell折射定律', r'$n_1\sin\theta_1=n_2\sin\theta_2$', 'n₁sinθ₁=n₂sinθ₂'),
    ('简谐行波', r'$u=A\cos(kx-\omega t+\phi)$', 'u=Acos(kx-ωt+ϕ)'),
    ('光栅衍射条件', r'$d\sin\theta=m\lambda$', 'dsinθ=mλ'),
  ],
  '流体力学': [
    ('Bernoulli能量方程', r'$p+\frac{1}{2}\rho v^2+\rho gh=C$', 'p+½ρv²+ρgh=C'),
    (
      '质量连续性',
      r'$\frac{\partial\rho}{\partial t}+\nabla\cdot(\rho\vec v)=0$',
      '(∂ρ)/(∂t)+∇·(ρv⃗)=0',
    ),
    (
      '线性化Navier-Stokes动量',
      r'$\rho\frac{\partial\vec v}{\partial t}=-\nabla p+\mu\nabla^2\vec v+\vec f$',
      'ρ(∂v⃗)/(∂t)=-∇p+μ∇²v⃗+f⃗',
    ),
  ],
  '材料与弹性力学': [
    ('单轴Hooke定律', r'$\sigma=E\epsilon$', 'σ=Eϵ'),
    ('剪切应力应变', r'$\tau=G\gamma$', 'τ=Gγ'),
    (
      '小应变张量',
      r'$\varepsilon_{ij}=\frac{1}{2}(\frac{\partial u_i}{\partial x_j}+\frac{\partial u_j}{\partial x_i})$',
      'εᵢⱼ=½((∂uᵢ)/(∂xⱼ)+(∂uⱼ)/(∂xᵢ))',
    ),
  ],
  '控制与Laplace': [
    ('传递函数定义', r'$G(s)=\frac{Y(s)}{U(s)}$', 'G(s)=(Y(s))/(U(s))'),
    ('二阶特征多项式', r'$s^2+2\zeta\omega_ns+\omega_n^2=0$', 's²+2ζωₙs+ωₙ²=0'),
    (
      '负反馈闭环传递函数',
      r'$T(s)=\frac{G(s)}{1+G(s)H(s)}$',
      'T(s)=(G(s))/(1+G(s)H(s))',
    ),
  ],
  '傅里叶与数字信号': [
    (
      '连续傅里叶变换',
      r'$F(\omega)=\int_{-\infty}^{\infty}f(t)e^{-i\omega t}dt$',
      'F(ω)=∫_(-∞)^(∞)f(t)e^(-iωt)dt',
    ),
    (
      '离散傅里叶变换',
      r'$X_k=\sum_{n=0}^{N-1}x_ne^{-i2\pi kn/N}$',
      'Xₖ=∑ₙ₌₀^(N-1)xₙe^(-i2πkn/N)',
    ),
    (
      'Laplace变换核',
      r'$F(s)=\int_0^{\infty}f(t)e^{-st}dt$',
      'F(s)=∫₀^(∞)f(t)e^(-st)dt',
    ),
  ],
  '信息论与算法': [
    ('Shannon熵', r'$H(X)=-\sum_i p_i\log_2 p_i$', 'H(X)=-∑ᵢpᵢlog₂pᵢ'),
    ('互信息', r'$I(X;Y)=H(X)+H(Y)-H(X,Y)$', 'I(X;Y)=H(X)+H(Y)-H(X,Y)'),
    ('归并排序复杂度', r'$T(n)=O(n\log n)$', 'T(n)=O(nlogn)'),
  ],
  '量子力学与张量': [
    (
      '含时Schrodinger方程',
      r'$i\hbar\frac{\partial\psi}{\partial t}=\hat H\psi$',
      'iℏ(∂ψ)/(∂t)=Ĥψ',
    ),
    ('定态能量本征方程', r'$\hat H\psi=E\psi$', 'Ĥψ=Eψ'),
    ('态内积', r'$\braket{\psi|\phi}$', '⟨ψ|ϕ⟩'),
    ('纯态密度算子', r'$\rho=\ket{\psi}\bra{\psi}$', 'ρ=|ψ⟩⟨ψ|'),
    ('度规线元缩并', r'$ds^2=g_{\mu\nu}dx^{\mu}dx^{\nu}$', 'ds²=g_(μν)dx^(μ)dx^(ν)'),
  ],
};
