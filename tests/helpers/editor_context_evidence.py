"""Verify actual same-session context references against previously delivered bytes.

This only decodes evidence, never alters transport, provider or editor data. Full
current-value equality remains the caller's assertion. Missing history, forged
identities and pretending a bounded subset is full are hard failures.
"""
import hashlib
import json

def identity(value):
    return hashlib.sha1(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()).hexdigest().upper()

def resolve_context(wire, previous):
    if isinstance(wire,dict) and 'completeContext' in wire:
        if set(wire)!={'completeContext'} or not isinstance(wire['completeContext'],dict):raise AssertionError('Malformed complete context')
        return wire['completeContext']
    if isinstance(wire,dict) and 'fromContext' in wire:
        if not {'fromContext','current'}.issubset(wire) or set(wire)-{'fromContext','current','boundedInherited','protectedV1','protectedV2'}:raise AssertionError('Malformed context envelope')
        if not isinstance(previous,dict) or wire['fromContext']!=identity(previous):raise AssertionError('Context envelope mismatches actual prior delivered representation')
        if not isinstance(wire['current'],dict):raise AssertionError('Malformed current context fields')
        protected={'accumulatedEdits','pendingSourceEdits','designSystemConstraints','currentFileDiffs','selectedStory','selectedElement'}
        result=dict(previous)
        if 'protectedV1' in wire and 'protectedV2' in wire:raise AssertionError('Duplicate protected versions')
        if 'protectedV1' in wire or 'protectedV2' in wire:
            version2='protectedV2' in wire
            values=wire['protectedV2' if version2 else 'protectedV1']
            fields=['accumulatedEdits','pendingSourceEdits','designSystemConstraints','currentFileDiffs']
            element=['id','sourceKey','domPath','schemaKey','tag','sourceFile','sourceLine','sourceColumn','properties','children','ancestors','ancestorIds','depth']
            if version2:element.append('styleBindings')
            if not isinstance(values,list) or len(values)!=6 or any(not isinstance(v,list) for v in values):raise AssertionError('Protected tuple arity/types')
            if len(values[4])!=4 or any(type(values[4][i]) is not (str if i<2 else int) for i in range(4)) or len(values[5])!=len(element):raise AssertionError('Target tuple arity/types')
            if any(type(v) is not (str if i<6 or i==13 else int if i in (6,7,12) else list) for i,v in enumerate(values[5])):raise AssertionError('Element tuple field types')
            if protected.intersection(wire['current']):raise AssertionError('Duplicate protected representation')
            result.update(zip(fields,values[:4]));result['selectedStory']=dict(zip(['group','name','kind','index'],values[4]));result['selectedElement']=dict(zip(element,values[5]))
        elif any(field in previous and field not in wire['current'] for field in protected):raise AssertionError('Protected fields must remain explicit')
        if not isinstance(wire.get('boundedInherited',[]),list):raise AssertionError('Bounded inherited fields must be an array')
        for field in wire.get('boundedInherited',[]):
            if not isinstance(field,str) or field in protected or field not in previous or field in wire['current']:raise AssertionError('Malformed bounded inherited field')
        for field,value in wire['current'].items():
            if isinstance(value,dict) and set(value)=={'fromPreviousItems'}:
                if field in protected:raise AssertionError('Protected fields cannot inherit records')
                if not isinstance(previous.get(field),list):raise AssertionError('Array delta lacks actual prior array')
                if not isinstance(value['fromPreviousItems'],list):raise AssertionError('Current record order must be an array')
                actual=[]
                for item in value['fromPreviousItems']:
                    if set(item) in ({'reuse'},{'reuse','set','remove'}):
                        index=item['reuse']
                        if type(index) is not int or index<0 or index>=len(previous[field]):raise AssertionError('Invalid actual prior record identity')
                        record=previous[field][index]
                        if 'set' in item:
                            if not isinstance(record,dict) or not isinstance(item['set'],dict) or not isinstance(item['remove'],list):raise AssertionError('Malformed changed record')
                            if any(not isinstance(key,str) for key in item['remove']) or len(set(item['remove']))!=len(item['remove']) or any(key not in record or key in item['set'] for key in item['remove']):raise AssertionError('Malformed removed keys')
                            record=dict(record)
                            for key in item['remove']:del record[key]
                            record.update(item['set'])
                        actual.append(record)
                    elif set(item)=={'value'}:actual.append(item['value'])
                    else:raise AssertionError('Malformed current context delta')
                result[field]=actual
            else:result[field]=value
        return result
    result={}
    for field,value in wire.items():
        if isinstance(value,dict) and set(value) in ({'previouslyDelivered'},{'unchangedSource','previouslyDelivered','bounded'}):
            if field not in previous:raise AssertionError('Context reference precedes actual delivery: '+field)
            if value['previouslyDelivered']!=identity(previous[field]):raise AssertionError('Context reference mismatches actual delivered bytes: '+field)
            if not value.get('bounded',False) and value.get('unchangedSource',value['previouslyDelivered'])!=value['previouslyDelivered']:raise AssertionError('Full reference claims a different source identity')
            result[field]=previous[field]
        elif isinstance(value,dict) and set(value)=={'fromDelivered','items'}:
            if field not in previous or not isinstance(previous[field],list):raise AssertionError('Array delta precedes actual delivery: '+field)
            if value['fromDelivered']!=identity(previous[field]):raise AssertionError('Array delta mismatches actual delivered bytes: '+field)
            actual=[]
            for item in value['items']:
                if set(item)=={'reuse'}:
                    index=item['reuse']
                    if not isinstance(index,int) or index<0 or index>=len(previous[field]):raise AssertionError('Invalid actual prior record identity')
                    actual.append(previous[field][index])
                elif set(item)=={'value'}:actual.append(item['value'])
                else:raise AssertionError('Malformed current context delta')
            result[field]=actual
        else:result[field]=value
    return result
