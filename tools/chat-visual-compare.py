#!/usr/bin/env python3
"""Per-view perceptual gate. Baselines require an explicit human acceptance record.
No automatic baseline writes or threshold adjustment. RGB noise <= 2/channel is
ignored; every view retains its own declared maximum changed-pixel ratio.
"""
import argparse,json,pathlib,struct,zlib
from chat_visual_guard import guard, accepted, require

def decode(path):
    raw=path.read_bytes();assert raw[:8]==b'\x89PNG\r\n\x1a\n';pos=8;blocks=[]
    while pos<len(raw):
        size=struct.unpack('>I',raw[pos:pos+4])[0];tag=raw[pos+4:pos+8];chunk=raw[pos+8:pos+8+size];pos+=size+12
        if tag==b'IHDR':
            width,height,depth,kind,*_=struct.unpack('>IIBBBBB',chunk)
            assert depth==8 and kind in (2,6), 'unsupported PNG format'
            channels=3 if kind==2 else 4
        if tag==b'IDAT':blocks.append(chunk)
    inflated=zlib.decompress(b''.join(blocks));stride=width*channels;previous=bytearray(stride);rows=[]
    for y in range(height):
        start=y*(stride+1);filter_kind=inflated[start];row=bytearray(inflated[start+1:start+stride+1])
        for i in range(stride):
            left=row[i-channels] if i>=channels else 0;above=previous[i];upper_left=previous[i-channels] if i>=channels else 0
            if filter_kind==1:row[i]=(row[i]+left)%256
            elif filter_kind==2:row[i]=(row[i]+above)%256
            elif filter_kind==3:row[i]=(row[i]+(left+above)//2)%256
            elif filter_kind==4:
                predicted=left+above-upper_left;distances=[abs(predicted-x) for x in [left,above,upper_left]]
                row[i]=(row[i]+[left,above,upper_left][distances.index(min(distances))])%256
            else:assert filter_kind==0
        rows.append(row);previous=row
    return width,height,channels,rows

def compare(candidate,baseline):
    assert candidate[:3]==baseline[:3], 'capture dimensions changed'
    width,height,channels,_=candidate;changed=0
    for y in range(height):
        for x in range(width):
            offset=x*channels
            if any(abs(candidate[3][y][offset+c]-baseline[3][y][offset+c])>2 for c in range(channels)):
                changed+=1
    return changed/(width*height)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');p.add_argument('--baseline');p.add_argument('--report',required=True);args=p.parse_args()
    pathlib.Path(args.report).write_text(json.dumps({'status':'failed-capture-validation','views':[]},indent=2)+'\n')
    candidate=pathlib.Path(args.candidate);manifest=guard(candidate,current=True)
    if not args.baseline:
        pathlib.Path(args.report).write_text(json.dumps({'status':'pending-human-baseline','views':[{'view':v['view'],'size':v['size'],'threshold':v['perceptualThreshold']} for v in manifest['views']]},indent=2)+'\n')
        raise SystemExit(2)
    baseline=pathlib.Path(args.baseline);prior=guard(baseline);accepted(prior)
    assert manifest['container']==prior['container'], 'container lineage differs'
    assert manifest['lineage']['browserExecutableSha256']==prior['lineage']['browserExecutableSha256'], 'browser lineage differs'
    assert manifest['lineage']['fonts']==prior['lineage']['fonts'], 'font lineage differs'
    for key in ['flags','environment','sizes','browser','node']:require(manifest[key]==prior[key],f'{key} lineage differs')
    old={(v['view'],v['size']):v for v in prior['views']};results=[]
    for view in manifest['views']:
        key=(view['view'],view['size']);assert key in old,'baseline view missing'
        candidate_png=candidate/view['file'];baseline_png=baseline/old[key]['file']
        ratio=0.0 if candidate_png.read_bytes()==baseline_png.read_bytes() else compare(decode(candidate_png),decode(baseline_png))
        maximum=old[key]['perceptualThreshold']['maximumChangedPixelRatio']
        assert view['perceptualThreshold']['maximumChangedPixelRatio']==maximum,'threshold changed; investigate capture, seek human review'
        results.append({'view':key[0],'size':key[1],'ratio':ratio,'maximum':maximum,'passed':ratio<=maximum})
    pathlib.Path(args.report).write_text(json.dumps({'status':'passed' if all(r['passed'] for r in results) else 'failed-human-review-required','views':results},indent=2)+'\n')
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)
