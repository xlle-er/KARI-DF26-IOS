"""Refresh pinned GGUF artifacts and only list byte-identical ModelScope mirrors."""
import concurrent.futures, json, subprocess
from pathlib import Path
MODELS = [
 ('embeddinggemma','EmbeddingGemma-300M','多语言推荐','ggml-org/embeddinggemma-300M-qat-q4_0-GGUF','embeddinggemma-300M-qat-Q4_0.gguf',768,2048,'mean','Gemma'),
 ('qwen','Qwen3-Embedding-0.6B','多语言进阶','Qwen/Qwen3-Embedding-0.6B-GGUF','Qwen3-Embedding-0.6B-Q8_0.gguf',1024,512,'last','Apache-2.0'),
 ('bge','BGE-small-zh-v1.5','中文轻量','CompendiumLabs/bge-small-zh-v1.5-gguf','bge-small-zh-v1.5-q8_0.gguf',512,512,'cls','MIT'),
 ('e5','multilingual-e5-small','多语言轻量','keisuke-miyako/multilingual-e5-small-gguf-q8_0','multilingual-e5-small-Q8_0.gguf',384,512,'mean','MIT'),
 ('minilm','all-MiniLM-L6-v2','英文轻量','second-state/All-MiniLM-L6-v2-Embedding-GGUF','all-MiniLM-L6-v2-Q8_0.gguf',384,256,'mean','Apache-2.0'),
]
def get(url):
 return json.loads(subprocess.check_output(['curl','-fLsS','--max-time','30',url]))
def model(row):
 id,name,subtitle,repo,file,dims,tokens,pool,license=row
 info=get('https://huggingface.co/api/models/'+repo)
 rev=info['sha']
 entry=next(x for x in get('https://huggingface.co/api/models/'+repo+'/tree/'+rev) if x['path']==file)
 sha=entry['lfs']['oid']; mirrors=[]
 try:
  files=get('https://modelscope.cn/api/v1/models/'+repo+'/repo/files?Revision=master&Recursive=true').get('Data',{}).get('Files',[])
  match=next((x for x in files if x.get('Path')==file and x.get('Sha256')==sha),None)
  if match:
   mirrors.append('https://modelscope.cn/models/'+repo+'/resolve/'+match['Revision']+'/'+file)
 except Exception as exc: print('Mirror unavailable:',repo,exc)
 print(name,entry['size'],'bytes; verified mirrors:',len(mirrors))
 return dict(id=id,name=name,subtitle=subtitle,repository=repo,revision=rev,filename=file,sha256=sha,bytes=entry['size'],dimensions=dims,maxTokens=tokens,pooling=pool,license=license,mirrors=mirrors)
if __name__=='__main__':
 models=list(concurrent.futures.ThreadPoolExecutor(max_workers=5).map(model,MODELS))
 root=Path(__file__).resolve().parents[1]
 (root/'Native/Sources/KariNative/Resources/Models/embedding-catalog.json').write_text(json.dumps(models,ensure_ascii=False,indent=2)+'\n')
