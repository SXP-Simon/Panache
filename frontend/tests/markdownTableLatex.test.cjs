const assert = require('node:assert/strict');
const {test} = require('node:test');
const modules = Promise.all([import('../src/utils/cleanMarkdown.ts'), import('../src/utils/latexToUnicode.ts')]);
const table = (body) => '| 项目 | 值 |\n|:---|---:|\n' + body;
test('Markdown defaults to editable LaTeX and converts to full grid', async()=>{
 const [{cleanMarkdown:clean},{convertLatexToUnicode:convert}] = await modules;
 const source = table('| 概率 | $\\frac8{15}$ |');
 const latex = clean(source);
 assert.ok(latex.includes('\\begin{array}{|c|c|}'));
 assert.ok(latex.includes('\\text{概率} & \\frac8{15}'));
 assert.equal(clean(latex),latex);
 assert.equal(convert(latex),'⟦ ── ; | 项目 | 值 | ; ── ; | 概率 | (8)/(15) | ; ── ⟧');
 assert.equal(clean(convert(latex)),convert(latex));
});
test('special cell text and inline math preserve contents without creating columns',async()=>{
 const [{cleanMarkdown:clean},{convertLatexToUnicode:convert}] = await modules;
 for(const [cell, expected] of [['`a|b`','"a|b"'],['a\\|b','"a|b"'],['`a ; b`','"a ; b"'],['$|x|$','"|x|"'],['text $x$ unit','text x unit'],['**重点**','重点'],['`a_b`','a_b'],['`a*b`','a*b']]) {
  const latex=clean(table(`| ${cell} | 1 |`));
  const output=convert(latex);
  assert.ok(output.includes(`| ${expected} | 1 |`),`${cell}: ${output}`);
  assert.equal(clean(output),output);
 }
});
test('short rows pad empty cells, no outer pipes work, and oversized rows remain text',async()=>{
 const [{cleanMarkdown:clean},{convertLatexToUnicode:convert}] = await modules;
 assert.ok(convert(clean('a | b\n--- | ---\nx |')).includes('| x |  |'));
 assert.ok(convert(clean(table('| | 1 |'))).includes('|  | 1 |'));
 for(const input of [table('| 1 | 2 | 3 |'), '| a | b |\n|---|\n|1|2|', table(Array.from({length:33},()=> '|1|2|').join('\n'))]) assert.ok(!clean(input).includes('\\begin{array}'));
});
test('code blocks and non-tables are not promoted to arrays',async()=>{
 const [{cleanMarkdown:clean}] = await modules;
 assert.ok(!clean('```\n'+table('|1|2|')+'\n```').includes('\\begin{array}'));
 for(const input of ['a | b\nc | d','| a | b |\n|--|--|\n|1|2|',table('')]) assert.ok(!clean(input).includes('\\begin{array}'));
});

test('serialized table cells remain unchanged across repeated cleanup and conversion',async()=>{
 const [{cleanMarkdown:clean},{convertLatexToUnicode:convert}] = await modules;
 for(const cell of ['a\\b','a\\\\b','a*bold*','text ⟧ text','"quoted"']) {
  const source='⟦ ── ; | A | B | ; ── ; | '+JSON.stringify(cell)+' | 1 | ; ── ⟧';
  assert.equal(convert(source),source);
  assert.equal(clean(source),source);
  assert.equal(convert(clean(convert(source))),source);
 }
});
