"""Add local physical-device test targets without changing the app's signing identity."""
from pathlib import Path
import subprocess,json,hashlib,re
root=Path(__file__).resolve().parents[1]
path=root/'KARI.xcodeproj/project.pbxproj'
project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(path)]))
objects=project['objects'];app=objects['504EC3031FED79650016851F'];proj=objects[project['rootObject']]
def uid(name):return hashlib.sha1(('kari.public.tests.'+name).encode()).hexdigest()[:24].upper()
def add(name,obj):key=uid(name);objects[key]=obj;return key
config=objects['504EC3171FED79650016851F']['buildSettings']
bundle=config['PRODUCT_BUNDLE_IDENTIFIER']
products=objects[proj['productRefGroup']]['children']
main=objects[proj['mainGroup']]['children']
refs=[];targets=[]
for name,ui,files in [('KariUnitTests',False,['MemoryRegressionTests.swift','LifeWakeTests.swift','FeaturePolicyTests.swift','DeviceRuntimeTests.swift','NativeRegressionTests.swift','RemoteRegressionTests.swift','SessionRegressionTests.swift']),('KariUITests',True,['KariUITests.swift'])]:
 targetID=uid(name);product=add(name+'product',{'isa':'PBXFileReference','explicitFileType':'wrapper.cfbundle','includeInIndex':'0','path':name+'.xctest','sourceTree':'BUILT_PRODUCTS_DIR'})
 if product not in products:products.append(product)
 sourceIDs=[]
 for file in files:
  ref=add(name+file,{'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':'Tests/device-native/'+file,'sourceTree':'SOURCE_ROOT'});refs.append(ref)
  sourceIDs.append(add(name+file+'build',{'isa':'PBXBuildFile','fileRef':ref}))
 resourceIDs=[]
 if not ui:
  ref=add('burger',{ 'isa':'PBXFileReference','lastKnownFileType':'image.jpeg','path':'Tests/device-native/burger.jpg','sourceTree':'SOURCE_ROOT'});refs.append(ref)
  resourceIDs.append(add('burgerbuild',{'isa':'PBXBuildFile','fileRef':ref}))
 sources=add(name+'sources',{'isa':'PBXSourcesBuildPhase','buildActionMask':'2147483647','files':sourceIDs,'runOnlyForDeploymentPostprocessing':'0'})
 resources=add(name+'resources',{'isa':'PBXResourcesBuildPhase','buildActionMask':'2147483647','files':resourceIDs,'runOnlyForDeploymentPostprocessing':'0'})
 frameworkFiles=[];dependencies=[]
 frameworks=add(name+'frameworks',{'isa':'PBXFrameworksBuildPhase','buildActionMask':'2147483647','files':frameworkFiles,'runOnlyForDeploymentPostprocessing':'0'})
 proxy=add(name+'proxy',{'isa':'PBXContainerItemProxy','containerPortal':project['rootObject'],'proxyType':'1','remoteGlobalIDString':'504EC3031FED79650016851F','remoteInfo':'App'})
 targetDep=add(name+'dependency',{'isa':'PBXTargetDependency','target':'504EC3031FED79650016851F','targetProxy':proxy})
 configs=[]
 for build in ['Debug','Release']:
  settings={'CODE_SIGN_STYLE':'Automatic','PRODUCT_BUNDLE_IDENTIFIER':bundle+'.'+name,'PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','IPHONEOS_DEPLOYMENT_TARGET':'15.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1,2','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'],'SWIFT_OPTIMIZATION_LEVEL':'-Onone','ENABLE_TESTABILITY':'YES'}
  if ui:settings['TEST_TARGET_NAME']='KARI'
  else:settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/KARI.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/KARI','BUNDLE_LOADER':'$(TEST_HOST)'})
  configs.append(add(name+build,{'isa':'XCBuildConfiguration','baseConfigurationReference':objects['504EC3171FED79650016851F']['baseConfigurationReference'],'buildSettings':settings,'name':build}))
 configList=add(name+'configs',{'isa':'XCConfigurationList','buildConfigurations':configs,'defaultConfigurationIsVisible':'0','defaultConfigurationName':'Debug'})
 add(name,{'isa':'PBXNativeTarget','buildConfigurationList':configList,'buildPhases':[sources,frameworks,resources],'buildRules':[],'dependencies':[targetDep],'name':name,'productName':name,'productReference':product,'productType':'com.apple.product-type.bundle.ui-testing' if ui else 'com.apple.product-type.bundle.unit-test','packageProductDependencies':dependencies})
 if targetID not in proj['targets']:proj['targets'].append(targetID)
 proj['attributes']['TargetAttributes'][targetID]={'CreatedOnToolsVersion':'26.0','TestTargetID':'504EC3031FED79650016851F','ProvisioningStyle':'Automatic'}
 targets.append((targetID,name))
group=add('group',{'isa':'PBXGroup','children':refs,'name':'Device tests','sourceTree':'<group>'})
if group not in main:main.append(group)
def encode(value,level=0):
 tab='\t'*level
 if isinstance(value,dict):return '{\n'+''.join(tab+'\t'+json.dumps(str(k))+' = '+encode(v,level+1)+';\n' for k,v in value.items())+tab+'}'
 if isinstance(value,list):return '(\n'+''.join(tab+'\t'+encode(v,level+1)+',\n' for v in value)+tab+')'
 return json.dumps(str(value),ensure_ascii=False)
path.write_text('// !$*UTF8*$!\n'+encode(project)+'\n')
scheme=root/'KARI.xcodeproj/xcshareddata/xcschemes/KARI.xcscheme';scheme.parent.mkdir(parents=True,exist_ok=True)
def ref(id,name,buildable):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id}" BuildableName="{buildable}" BlueprintName="{name}" ReferencedContainer="container:KARI.xcodeproj"/>'
appRef=ref('504EC3031FED79650016851F','KARI','KARI.app')
entries=''.join(f'<TestableReference skipped="NO">{ref(id,name,name+".xctest")}</TestableReference>' for id,name in targets)
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appRef}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{entries}</Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appRef}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appRef}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Configured physical-device unit and UI test targets; existing signing identity retained.')
