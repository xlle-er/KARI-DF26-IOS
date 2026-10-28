import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'kari-icon-'));
try {
 const png=path.join(temp,'rounded.png');
 execFileSync('/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool',[path.join(root,'App/AppIcon.icon'),'--export-image','--output-file',png,'--platform','iOS','--rendition','Default','--width','1024','--height','1024','--scale','1','--design-generation','26'],{stdio:'inherit'});
 execFileSync('swift',[path.join(root,'scripts/render-icon.swift'),png,path.join(root,'icon.png'),'1024','opaque'],{stdio:'inherit'});
 const catalog=path.join(root,'App/Assets.xcassets/AppIcon.appiconset');
 const contents=JSON.parse(fs.readFileSync(path.join(catalog,'Contents.json')));
 for(const image of contents.images) if(image.filename) fs.copyFileSync(path.join(root,'icon.png'),path.join(catalog,image.filename));
 const docs=path.join(root,'docs/assets');fs.mkdirSync(docs,{recursive:true});
 fs.copyFileSync(png,path.join(docs,'app-icon-rounded.png'));
 const inner = name => fs.readFileSync(path.join(root,'App/AppIcon.icon/Assets',name),'utf8').replace(/^.*?<title>.*?<\/title>/s,'').replace(/<\/svg>\s*$/,'');
 fs.writeFileSync(path.join(docs,'app-icon-rounded.svg'),`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="KARI app icon"><defs><clipPath id="rounded"><rect width="1024" height="1024" rx="224"/></clipPath></defs><g clip-path="url(#rounded)"><rect width="1024" height="1024" fill="#F8FAFD"/>${inner('KARI-Grid.svg')}${inner('KARI-Mark.svg')}</g></svg>\n`);
} finally { fs.rmSync(temp,{recursive:true,force:true}); }
