// Raw source is the interchange format: editing tools must not rewrite labels,
// coordinates or connection order before the Rust circuit renderer sees it.
const circuitExamples = <String, String>{
  'series RLC': r'''\begin{circuitikz}[american]
\draw (0,0) to[V,l=$U_s$] (0,3)
  to[R,l=$R_1$] (3,3) to[L,l=$L$] (6,3)
  to[C,l=$C$] (6,0) -- (0,0);
\end{circuitikz}''',
  'parallel named coordinates': r'''\begin{circuitikz}
\coordinate (top) at (0,3);
\coordinate (bottom) at (0,0);
\draw (bottom) to[I,l=$I_s$] (top) -- (4,3)
  to[R,l=$R_2$,i>^=$i_R$] (4,0) -- (bottom);
\draw (2,3) to[C,l=$C_1$] (2,0);
\end{circuitikz}''',
  'relative RC filter': r'''\begin{circuitikz}
\draw (0,0) to[V,l=$u_i$] ++(0,3)
  to[R,l=$R$] ++(3,0) to[C,l=$C$] ++(0,-3)
  -- (0,0);
\end{circuitikz}''',
};
