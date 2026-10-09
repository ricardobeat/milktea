import test from 'node:test';
import assert from 'node:assert/strict';
import {highlightJavaScript} from '../highlight.mjs';

test('highlighter colors JavaScript without interpreting HTML in editor text',()=>{
  const output=highlightJavaScript(`const x = '<script>alert("hi")</script>'; // <img src=x onerror=alert(1)>\nreturn 12;`);
  assert.match(output,/<span class="token-keyword">const<\/span>/);
  assert.match(output,/<span class="token-number">12<\/span>/);
  assert.ok(!output.includes('<script>'));assert.ok(!output.includes('<img'));
  assert.match(output,/&lt;script&gt;/);
  assert.match(output,/<span class="token-comment">\/\/ &lt;img/);
});
test('highlighter preserves multiline templates, Unicode, escapes and incomplete edits',()=>{
  for(const source of ['/* open comment\n<','"unfinished <','const π = `hello\n世界`;','// x\n\n',"'escaped \\' quote'",'0xff + 1.2e3']) {
    const plain=highlightJavaScript(source).replace(/<span class="[^"]+">|<\/span>/g,'').replace(/&(amp|lt|gt|quot|#39);/g,(_,entity)=>({amp:'&',lt:'<',gt:'>',quot:'"','#39':"'"}[entity]));
    assert.equal(plain,source);
  }
});
