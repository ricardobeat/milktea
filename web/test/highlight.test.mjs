import test from 'node:test';
import assert from 'node:assert/strict';
import {highlightJavaScript} from '../highlight.mjs';

test('highlighter colors JavaScript without interpreting HTML in editor text',()=>{
  const output=highlightJavaScript(`const x = '<script>alert("hi")</script>'; // <img src=x onerror=alert(1)>\nreturn 12;`);
  assert.match(output,/<span class="hljs-keyword">const<\/span>/);
  assert.match(output,/<span class="hljs-number">12<\/span>/);
  assert.ok(!output.includes('<script>'));assert.ok(!output.includes('<img'));
  assert.match(output,/&lt;script&gt;/);
  assert.match(output,/<span class="hljs-comment">\/\/ &lt;img/);
});
test('highlighter preserves multiline templates, Unicode, escapes and incomplete edits',()=>{
  for(const source of ['/* open comment\n<','"unfinished <','const π = `hello\n世界`;','// x\n\n',"'escaped \\' quote'",'0xff + 1.2e3']) {
    const plain=highlightJavaScript(source).replace(/<span class="[^"]+">|<\/span>/g,'').replace(/&(amp|lt|gt|quot|#39|#x27);/g,(_,entity)=>({amp:'&',lt:'<',gt:'>',quot:'"','#39':"'",'#x27':"'"}[entity]));
    assert.equal(plain,source);
  }
});

test('JavaScript grammar recognizes functions, regex literals, properties and template substitutions',()=>{
  const source='async function greet(name) { const styles = { foreground: "#fff" }; return /hello/i.test(`hello ${name}`); }';
  const output=highlightJavaScript(source);
  for (const token of ['hljs-title function_', 'hljs-regexp', 'hljs-attr', 'hljs-subst']) {
    assert.ok(output.includes(`class="${token}"`), `missing ${token}`);
  }
});
