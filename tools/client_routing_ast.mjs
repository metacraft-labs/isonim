#!/usr/bin/env node
/** Complete syntax catalog for the finite private routing artifact.
 * Acorn, rather than a source regex, visits computed properties, anonymous
 * callbacks, constructors and all module initialization. This is an inventory;
 * only separate reviewed identities/provenance can authorize an exact artifact.
 */
import {parse} from '../node_modules/acorn/dist/acorn.mjs';
import {parse as parseHtml} from '../node_modules/parse5/dist/index.js';
import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
const hash=text=>createHash('sha256').update(text).digest('hex');

export function catalogArtifact(source){
 const tree=parse(source,{ecmaVersion:2024,sourceType:'script',allowHashBang:true});
 const result={output_sha256:hash(source),nodes:[],functions:[],members:[],calls:[],constructors:[],identifiers:[],initializers:[],node_types:[]};
 const types=new Set();
 function spelling(node){return source.slice(node.start,node.end);}
 function visit(node,owner='<module-init>',parent=null){
  if(!node||typeof node.type!=='string')throw Error('unknown AST child');
  const record={type:node.type,start:node.start,end:node.end,owner,sha256:hash(spelling(node))};
  types.add(node.type);result.nodes.push(record);
  if(parent?.type==='Program'&&node.type!=='FunctionDeclaration')result.initializers.push(record);
  if(['FunctionDeclaration','FunctionExpression','ArrowFunctionExpression'].includes(node.type)){
   owner=node.id?.name||'<'+node.type+'@'+node.start+'>';
   result.functions.push({...record,name:owner,async:node.async,generator:node.generator});
  }
  if(node.type==='MemberExpression'){
   const property=node.computed?(node.property.type==='Literal'&&typeof node.property.value==='string'?node.property.value:null):node.property.name;
   result.members.push({...record,owner,computed:node.computed,property,empty_assignment:parent?.type==='AssignmentExpression'&&parent.left===node&&parent.operator==='='&&parent.right.type==='Literal'&&parent.right.value==='',object:spelling(node.object),expression:spelling(node)});
  }
  if(node.type==='CallExpression'||node.type==='NewExpression'){
   result[node.type==='CallExpression'?'calls':'constructors'].push({...record,owner,callee:spelling(node.callee),callee_type:node.callee.type,optional:node.optional||false});
  }
  if(node.type==='Identifier')result.identifiers.push({...record,owner,name:node.name});
  for(const [key,value] of Object.entries(node)){
   if(['type','start','end'].includes(key))continue;
   if(Array.isArray(value)){
    for(const child of value)if(child&&typeof child==='object'&&typeof child.type==='string')visit(child,owner,node);
   }else if(value&&typeof value==='object'&&typeof value.type==='string')visit(value,owner,node);
  }
 }
 visit(tree);result.node_types=[...types].sort();return result;
}

/** Inspect only our exact generated SSR resources, not arbitrary HTML policy. */
export function catalogHtmlScripts(html){
 const tree=parseHtml(html,{sourceCodeLocationInfo:true});
 const allowed=new Set(['html','head','body','main','div','h1','h2','form','input','button','ul','li','b','script']);
 const scripts=[],elements=[];
 function visit(node){
  if(node.tagName){
   if(!allowed.has(node.tagName))throw Error('unaccounted SSR element: '+node.tagName);
   for(const attr of node.attrs){
    if(attr.name.startsWith('on')||attr.value.trim().toLowerCase().startsWith('javascript:'))throw Error('unaccounted SSR executable attribute');
   }
   elements.push({tag:node.tagName,attrs:node.attrs});
   if(node.tagName==='script'){
    if(node.attrs.some(attr=>attr.name==='src'||attr.name==='type'))throw Error('unaccounted SSR script source/type');
    const code=node.childNodes.map(child=>child.value||'').join('');
    scripts.push({source_sha256:hash(code),catalog:catalogArtifact(code)});
   }
  }
  for(const child of node.childNodes||[])visit(child);
  if(node.content)visit(node.content);
 }
 visit(tree);return {html_sha256:hash(html),elements,scripts};
}

export function titleMismatch(html){
 const tree=parseHtml(html,{sourceCodeLocationInfo:true}),titles=[];
 function visit(node){if(node.tagName==='h1')titles.push(node);for(const child of node.childNodes||[])visit(child);}
 visit(tree);if(titles.length!==1)throw Error('actual task title is missing/ambiguous');
 const loc=titles[0].sourceCodeLocation;if(!loc?.startTag||!loc?.endTag)throw Error('actual task title locations missing');
 const a=loc.startTag.startOffset,b=loc.endTag.startOffset;
 if(!html.slice(a).startsWith('<h1')||!html.slice(b).startsWith('</h1>'))throw Error('actual task title shape changed');
 // Change only the two tag-name bytes. Never serialize/normalize the rest of
 // the actual SSR output, bootstrap, attributes, data-hk keys or text.
 return html.slice(0,a)+html.slice(a,b).replace(/^<h1\b/,'<h2')+html.slice(b).replace(/^<\/h1\b/,'</h2');
}

export async function main(args=process.argv.slice(2)){
 if(args.length===3&&args[0]==='--html'){
  const result=catalogHtmlScripts(await readFile(args[1],'utf8'));
  await writeFile(args[2],JSON.stringify(result,null,2)+'\n');return result;
 }
 if(args.length===5&&args[0]==='--html-variants'){
  const original=await readFile(args[1],'utf8'),mismatch=titleMismatch(original);
  await writeFile(args[2],JSON.stringify(catalogHtmlScripts(original),null,2)+'\n');
  await writeFile(args[3],mismatch);
  await writeFile(args[4],JSON.stringify(catalogHtmlScripts(mismatch),null,2)+'\n');
  return;
 }
 if(args.length!==2)throw Error('usage: client_routing_ast.mjs INPUT.js OUTPUT.json, or --html-variants INPUT.html BASE.json MISMATCH.html MISMATCH.json');
 const result=catalogArtifact(await readFile(args[0],'utf8'));
 await writeFile(args[1],JSON.stringify(result,null,2)+'\n');return result;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 main().catch(error=>{console.error(error);process.exitCode=1;});
}
