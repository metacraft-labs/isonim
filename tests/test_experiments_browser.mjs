// Real SSR compiler output in Chromium. No network services or mocked DOM.
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
import {execFileSync} from 'node:child_process';
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {manifest} from './test_experiment_manifest.mjs';
test('e2e_experiment_hydrates_without_mismatch', async () => {
const out = new URL('../build/experiments/', import.meta.url);
const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || execFileSync('which',['chromium'],{encoding:'utf8'}).trim(),args:['--no-sandbox']});
try {
  for (const plain of [false,true]) {
    const page=await browser.newPage();
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    const markup=readFileSync(new URL('markup.html',out),'utf8'), split=markup.indexOf('<script>');
    await page.setContent('<!doctype html><div id="root">'+markup.slice(0,split)+'</div>'+markup.slice(split));
    await page.addScriptTag({content:readFileSync(new URL(plain?'plain.js':'app.js',out),'utf8')});
    assert.equal(await page.evaluate(()=>globalThis.experimentInjected),undefined,'script payload executed');
    assert.equal(await page.evaluate(()=>Object.hasOwn(globalThis._$HY.r.$exp.assign,'__proto__')),true);
    assert.equal(await page.evaluate(()=>globalThis._$HY.r.$exp.assign.__proto__),1);
    assert.equal(await page.evaluate(()=>Object.hasOwn(globalThis._$HY.r,'__proto__')),true);
    assert.equal(await page.evaluate(()=>globalThis._$HY.r.__proto__.sentinel),true);
    assert.equal(await page.evaluate(()=>Object.getPrototypeOf(globalThis._$HY.r)===Object.prototype),true);
    assert.deepEqual(errors,[]);
    const actual=await page.evaluate(()=>({mismatches:globalThis.isonimHy.mismatches,exposed:globalThis._$HY.r.$exp.exposed,text:document.querySelector('#root').textContent}));
    if (plain) assert(actual.mismatches>0,'plain hydrate must detect the wrong arm');
    else {
      assert.equal(actual.mismatches,0);assert.equal(actual.text.trim(),'Estimate');
      assert.deepEqual(actual.exposed.map(e=>e.key),['home-cta','Color']);
      assert.deepEqual(actual.exposed.map(e=>e.arm),[1,0]);
      assert(actual.exposed.every(e=>e.callSite.length===12));
      for (const exposure of actual.exposed)
        assert(manifest.experiments[exposure.key].callSites.some(s=>s.id===exposure.callSite));
      const client=await page.evaluate(()=>globalThis.clientExperimentResource);
      assert.deepEqual(client.exposed,actual.exposed);
      // Check own-property semantics in Chromium itself, before Playwright's
      // object transport can normalize a prototype-named property.
      assert.equal(await page.evaluate(()=>Object.hasOwn(globalThis.clientExperimentResource.assign,'__proto__')),true);
      assert.equal(await page.evaluate(()=>globalThis.clientExperimentResource.assign.__proto__),1);
      assert.equal(await page.evaluate(()=>globalThis._$HY.r.$exp.day),'2026-10-22</script><script>globalThis.experimentInjected=1</script>');
    }
    await page.close();
  }
} finally {await browser.close();}
console.log('e2e_experiment_hydrates_without_mismatch passed; plain hydrate mismatched');
});
