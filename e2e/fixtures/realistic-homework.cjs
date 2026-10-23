const circuits = require('./realistic-circuits.json');

const pages = [
  String.raw`# 电路分析作业 · 节点电压法
已知 U_s=12 V，I_s=1 mA；R₁=R₂=2 kΩ，R₃=1 kΩ，R₄=3 kΩ。
${circuits[0].source}
取下方导线为参考地，电流单位 mA，电压单位 V。
\[\begin{aligned}2U_A-U_B&=6\\-U_A+\frac43U_B&=1\end{aligned}\]
解得 U_A=5.4 V，U_B=4.8 V。
支路电流：I₁=3.3，I₂=2.7，I₃=0.6，I₄=1.6 mA。
校核：A 点 3.3=2.7+0.6；B 点 0.6+1=1.6。
功率平衡：电源提供 44.4 mW，四个电阻共消耗 44.4 mW。`,
  String.raw`# 模拟电路作业 · 两级无源 RC 网络
R₁=R₂=1 kΩ，C₁=C₂=1 μF，输入 u_s(t)=3sin(1000t) V。
${circuits[1].source}
令 τ=RC=1 ms，按节点电压列式：
\[\begin{pmatrix}2+s\tau&-1\\-1&1+s\tau\end{pmatrix}\begin{pmatrix}U_1\\U_o\end{pmatrix}=\begin{pmatrix}U_s\\0\end{pmatrix}\]
\[H(s)=\frac{U_o}{U_s}=\frac{1}{\tau^2s^2+3\tau s+1}\]
在 ω=1000 rad/s 时，H(jω)=−j/3，幅值为 1/3，相位 −90°。
所以稳态输出 u_o(t)=sin(1000t−π/2) V。
注意：第二级会加载第一级，不能直接将两个独立低通响应相乘。`,
  String.raw`# 电路分析作业 · 非平衡电桥
U_s=10 V，R₁=R₄=R₅=1 kΩ，R₂=R₃=2 kΩ。
${circuits[2].source}
桥支路 R₅ 有电流，不能按两组独立分压计算。
\[\begin{aligned}\frac52U_A-U_B&=10\\-U_A+\frac52U_B&=5\end{aligned}\]
\[U_A=\frac{40}{7}\ \mathrm V,\quad U_B=\frac{30}{7}\ \mathrm V\]
桥支路电流 I₅=(U_A−U_B)/R₅=10/7 mA，方向 A→B。
校核：I₁=30/7，I₂=20/7，I₃=20/7，I₄=30/7 mA。`,
  String.raw`# 电力电子作业 · 桥式整流与滤波
变压器次级接 a、b，U₂=12 V（有效值），f=50 Hz。
${circuits[3].source}
假设二极管理想，R_L=1 kΩ，C=1000 μF。
电容充电峰值约为 U_p=12√2≈16.97 V。
全波整流纹波频率 f_r=2f=100 Hz。
小纹波近似：\[\Delta U\approx\frac{I_L}{f_r C},\quad U_o\approx U_p-\frac{\Delta U}{2}\]
由 I_L≈U_o/R_L，估得 U_o≈16.89 V，ΔU≈0.169 V。
该估计忽略二极管压降、变压器内阻与电容 ESR。`,
  String.raw`# 概率论作业 · 离散分布与矩
抛掷三枚独立均匀硬币，X 表示正面朝上的枚数。
| X | 0 | 1 | 2 | 3 |
| --- | --- | --- | --- | --- |
| P | $\frac18$ | $\frac38$ | $\frac38$ | $\frac18$ |
\[\sum_{k=0}^{3}P(X=k)=\frac{1+3+3+1}{8}=1\]
\[E(X)=\sum_{k=0}^{3}kP(X=k)=\frac32\]
\[E(X^2)=3,\qquad D(X)=3-\left(\frac32\right)^2=\frac34\]
条件分布：已知 X≥2，则 P(X=2|X≥2)=3/4。
## 数值积分 · 复合 Simpson 校验
\[\int_0^1e^x\,dx\approx\frac{h}{3}(f_0+4f_1+2f_2+4f_3+f_4),\quad h=\frac14\]
近似值 1.7183188419，精确值 e−1≈1.7182818285。
绝对误差约为 3.70×10⁻⁵。`,
  String.raw`# 普通化学作业 · 方程式与离子电荷
## 氨的合成（配平）
\[\ce{N2 + 3H2 <=> 2NH3}\]
## 铵盐的电离
\[\ce{(NH4)2SO4 -> 2NH4+ + SO4^2-}\]
注意：NH₄⁺ 中 4 是氢的个数，+ 是整个离子的电荷。
## 沉淀反应
\[\ce{Ag+ + Cl- -> AgCl v}\]
## 含结晶水的物质
\[\ce{CuSO4 * 5H2O}\]
## 物理量与单位
\[F=ma,\quad a=\qty{9.81}{\metre\per\second\squared}\]
\[Q=It,\quad I=\SI{2.5}{\milli\ampere},\quad t=\SI{30}{\second}\]
所以 Q=0.075 C。
## 酸性条件下的氧化还原（电子守恒）
\[\ce{Cr2O7^2- + 14H+ + 6e- -> 2Cr^3+ + 7H2O}\]`,
  String.raw`# 高等数学与力学作业 · 导数与范数
## 质点运动
位移 x(t)=t³−2t，求速度和加速度。
\[v(t)=\dv{x}{t}=3t^2-2,\quad a(t)=\dv[2]{x}{t}=6t\]
在 t=2 s 时，速度 v=10 m/s，加速度 a=12 m/s²。
## 二元函数的偏导
\[f(x,y)=x^2y+\sin y\]
\[\pdv{f}{x}=2xy,\qquad \pdv{f}{y}=x^2+\cos y\]
\[\pdv[2]{f}{x}=2y\]
## 向量长度与绝对值
\[\mathbf v=(3,4),\quad\norm{\mathbf v}=\sqrt{3^2+4^2}=5\]
\[\abs{-3}=3,\qquad \norm{\mathbf u+\mathbf v}\le\norm{\mathbf u}+\norm{\mathbf v}\]
单变量微分算子也可写作：\[\dv{x} x^3=3x^2\]`,
];

module.exports = pages;
