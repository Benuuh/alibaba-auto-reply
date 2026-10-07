const fs=require('fs'),vm=require('vm'),assert=require('assert');
const source=fs.readFileSync(process.argv[2],'utf8');
const visible=node=>Object.assign(node,{isConnected:true,getClientRects(){return this.hidden?[]:[{}];}});
const tab=(active=true,hidden=false)=>visible({innerText:'待回复',className:active?'list-tab-item active':'list-tab-item',hidden});
const item=(name,hidden=false)=>visible({innerText:name||'Old preview fallback',hidden,querySelector(){return name?{innerText:name}:null;}});
function run(tabs,items){return vm.runInNewContext(source,{document:{querySelectorAll(s){return s==='.list-tab-item'?tabs:items;}}});}
assert.strictEqual(run([tab(false)],[item('Buyer A')]),'PENDING_TAB_UNVERIFIED');
assert.strictEqual(run([],[item('Buyer A')]),'PENDING_TAB_UNVERIFIED');
assert.strictEqual(run([tab(),tab()],[item('Buyer A')]),'PENDING_TAB_UNVERIFIED');
assert.strictEqual(run([tab()],[item('')]),'PENDING_NAME_UNVERIFIED');
assert.strictEqual(run([tab()],[item('Buyer A',true)]),'[]');
assert.deepStrictEqual(JSON.parse(run([tab(),tab(true,true)],[item('Buyer A'),item('Buyer B')] )).map(x=>x.name),['Buyer A','Buyer B']);
assert.strictEqual(JSON.parse(run([tab()],[item('Buyer A'),item('Buyer A')])).length,1);
assert.strictEqual(JSON.parse(run([tab()],[item('__proto__')])).length,1);
console.log('RESULT pending_list pass=8 fail=0');
