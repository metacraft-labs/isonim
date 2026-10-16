/** DOM geometry shared by mounted behavior tests and every campaign view.
 * No substitute renderer: observes the actual sidebar, textarea, send button and
 * every clipping ancestor. Border/client bounds include overflow hidden/clip/scroll.
 */
import assert from 'node:assert/strict';
export async function horizontalChatGuard(page) {
 const evidence=await page.evaluate(()=>{
  const targets={sidebar:document.querySelector('.editor-ai-assistant'),
    conversation:document.querySelector('.editor-chat'),
    composer:document.querySelector('.editor-chat [aria-label="Agent prompt"]'),
    send:document.querySelector('.editor-chat [aria-label="Send agent prompt"]')};
  return Object.entries(targets).map(([name,el])=>{
   if(!el)return {name,missing:true};
   const box=el.getBoundingClientRect();const clippedBy=[];
   if(box.left<0||box.right>innerWidth)clippedBy.push({ancestor:'viewport',left:0,right:innerWidth});
   for(let ancestor=el.parentElement;ancestor;ancestor=ancestor.parentElement){
    const style=getComputedStyle(ancestor);
    if(['hidden','clip','auto','scroll'].includes(style.overflowX)){
     const bounds=ancestor.getBoundingClientRect();const left=bounds.left+ancestor.clientLeft;
     const right=left+ancestor.clientWidth;
     if(box.left<left||box.right>right)clippedBy.push({ancestor:ancestor.className||ancestor.tagName,left,right});
    }
   }
   return {name,left:box.left,right:box.right,width:box.width,clippedBy};
  });
 });
 assert(evidence.every(row=>!row.missing&&row.width>0&&row.clippedBy.length===0),
   'horizontal chat clipping '+JSON.stringify(evidence));
 return evidence;
}
export async function oldClippedChatControl(page) {
 const panel=page.locator('.editor-chat');const original=await panel.getAttribute('style');
 try {
  // Recreate the original tablet media rule on the nested content, with its
  // original 320px minimum, inside the actual production 240px assistant rail.
  await panel.evaluate(el=>{el.style.setProperty('width','320px','important');el.style.setProperty('min-width','320px','important');el.style.setProperty('max-width','320px','important');});
  await assert.rejects(()=>horizontalChatGuard(page),/horizontal chat clipping/,
    'same every-view guard must reject original clipped nested chat');
 } finally {await panel.evaluate((el,style)=>el.setAttribute('style',style),original);}
 return horizontalChatGuard(page);
}
