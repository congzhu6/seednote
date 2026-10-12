#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. Run after adding Swift/resources files."""
from pathlib import Path
import argparse, hashlib, json, subprocess
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--development-team', help='Set the signing Team ID for all targets; otherwise preserve existing selections.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
project = root/'Seednote.xcodeproj'
project_file = project/'project.pbxproj'
# Read Xcode's existing configuration before replacing the generated project.
# plutil supports the OpenStep plist format that plistlib cannot read directly.
existing_settings = {}
if project_file.exists():
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(project_file)], check=True, capture_output=True)
    existing_objects = json.loads(result.stdout)['objects']
    owners = {'Seednote': 'app-config', 'SeednoteUITests': 'test-config', 'SeednoteAppTests': 'unit-config'}
    for owner in existing_objects.values():
        if owner.get('isa') == 'PBXProject':
            key = 'project-config'
        elif owner.get('isa') == 'PBXNativeTarget':
            key = owners.get(owner.get('name'))
        else:
            continue
        if key is None:
            continue
        configuration_list = existing_objects[owner['buildConfigurationList']]
        for identifier in configuration_list['buildConfigurations']:
            configuration = existing_objects[identifier]
            settings = configuration.get('buildSettings', {})
            existing_settings[key, configuration['name']] = {
                field: settings[field] for field in ('DEVELOPMENT_TEAM', 'PRODUCT_BUNDLE_IDENTIFIER', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION') if field in settings
            }
objects = {}
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key, **props):
    identifier = uid(key); objects[identifier] = props; return identifier

def buildfile(path, filetype):
    ref = add('file:'+path, isa='PBXFileReference', lastKnownFileType=filetype, path=path, sourceTree='<group>')
    build = add('build:'+path, isa='PBXBuildFile', fileRef=ref)
    return ref, build
sources, test_sources, unit_sources, resources, refs = [], [], [], [], []
for path in sorted(root.rglob('*.swift')):
    relative = path.relative_to(root).as_posix()
    if relative.startswith(('App/', 'Core/', 'UITests/', 'AppTests/')):
        ref, build = buildfile(relative, 'sourcecode.swift'); refs.append(ref)
        (test_sources if relative.startswith('UITests/') else unit_sources if relative.startswith('AppTests/') else sources).append(build)
for path in sorted((root/'Resources').rglob('*')):
    if path.is_file() and path.name not in ('Info.plist',) and '.xcassets/' not in str(path):
        rel = path.relative_to(root).as_posix()
        typ = {'.strings': 'text.plist.strings', '.xcprivacy': 'text.xml', '.png': 'image.png'}.get(path.suffix, 'file')
        ref, build = buildfile(rel, typ); refs.append(ref); resources.append(build)
# The asset catalog supplies the App Store icon; App Store Connect rejects builds without it.
ref, build = buildfile('Resources/Assets.xcassets', 'folder.assetcatalog'); refs.append(ref); resources.append(build)
# localized permission strings as PBXVariantGroup to avoid duplicate output names
for filename in ['InfoPlist.strings', 'Localizable.strings']:
    localized = [r for r in refs if objects[r].get('path','').endswith(filename)]
    if localized:
        for r in localized:
            path = objects[r]['path']; objects[r]['name'] = path.split('/')[-2].replace('.lproj','')
            resources.remove(uid('build:'+path)); refs.remove(r)
        group = add('localized-'+filename, isa='PBXVariantGroup', children=localized, name=filename, sourceTree='<group>')
        refs.append(group); resources.append(add('build-localized-'+filename, isa='PBXBuildFile', fileRef=group))
app = add('app-product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Seednote.app', sourceTree='BUILT_PRODUCTS_DIR')
test = add('test-product', isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='SeednoteUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
unit = add('unit-product', isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='SeednoteAppTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', isa='PBXGroup', children=[app,test,unit], name='Products', sourceTree='<group>')
group = add('rootgroup', isa='PBXGroup', children=refs+[products], sourceTree='<group>')

def phase(key, isa, files): return add(key, isa=isa, buildActionMask='2147483647', files=files, runOnlyForDeploymentPostprocessing='0')
def configs(key, extra):
    cs=[]
    for name in ['Debug','Release']:
        bs={'SWIFT_VERSION':'5.0', 'IPHONEOS_DEPLOYMENT_TARGET':'18.0', 'SDKROOT':'iphoneos', 'TARGETED_DEVICE_FAMILY':'1', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO', 'CODE_SIGN_STYLE':'Automatic', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O', 'DEBUG_INFORMATION_FORMAT':'dwarf' if name=='Debug' else 'dwarf-with-dsym', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else '', 'GENERATE_INFOPLIST_FILE':'NO'}
        bs.update(extra)
        if key == 'app-config' and name == 'Debug':
            bs['ENABLE_TESTABILITY'] = 'YES'
        if key == 'unit-config':
            app_team = existing_settings.get(('app-config', name), {}).get('DEVELOPMENT_TEAM')
            if app_team:
                bs['DEVELOPMENT_TEAM'] = app_team
        bs.update(existing_settings.get((key, name), {}))
        if args.development_team is not None and key in ('app-config', 'test-config', 'unit-config'):
            bs['DEVELOPMENT_TEAM'] = args.development_team
        cs.append(add(key+name, isa='XCBuildConfiguration', buildSettings=bs, name=name))
    return add(key+'list', isa='XCConfigurationList', buildConfigurations=cs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
app_target=uid('app-target'); test_target=uid('test-target'); unit_target=uid('unit-target'); project_id=uid('project')
proxy=add('proxy', isa='PBXContainerItemProxy', containerPortal=project_id, proxyType='1', remoteGlobalIDString=app_target, remoteInfo='Seednote')
dep=add('dependency', isa='PBXTargetDependency', target=app_target, targetProxy=proxy)
add('app-target', isa='PBXNativeTarget', buildConfigurationList=configs('app-config',{'PRODUCT_BUNDLE_IDENTIFIER':'com.seednote.app','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Resources/Info.plist', 'MARKETING_VERSION':'0.1.0','CURRENT_PROJECT_VERSION':'1','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'}), buildPhases=[phase('app-sources','PBXSourcesBuildPhase',sources),phase('app-frameworks','PBXFrameworksBuildPhase',[]),phase('app-resources','PBXResourcesBuildPhase',resources)],buildRules=[],dependencies=[],name='Seednote',productName='Seednote',productReference=app,productType='com.apple.product-type.application')
add('test-target', isa='PBXNativeTarget', buildConfigurationList=configs('test-config',{'PRODUCT_BUNDLE_IDENTIFIER':'com.seednote.app.uitests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_TARGET_NAME':'Seednote'}), buildPhases=[phase('test-sources','PBXSourcesBuildPhase',test_sources),phase('test-frameworks','PBXFrameworksBuildPhase',[])],buildRules=[],dependencies=[dep],name='SeednoteUITests',productName='SeednoteUITests',productReference=test,productType='com.apple.product-type.bundle.ui-testing')
add('unit-target', isa='PBXNativeTarget', buildConfigurationList=configs('unit-config',{'PRODUCT_BUNDLE_IDENTIFIER':'com.seednote.app.apptests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Seednote.app/Seednote','BUNDLE_LOADER':'$(TEST_HOST)'}), buildPhases=[phase('unit-sources','PBXSourcesBuildPhase',unit_sources),phase('unit-frameworks','PBXFrameworksBuildPhase',[])],buildRules=[],dependencies=[dep],name='SeednoteAppTests',productName='SeednoteAppTests',productReference=unit,productType='com.apple.product-type.bundle.unit-test')
add('project', isa='PBXProject', attributes={'LastUpgradeCheck':'2630','TargetAttributes':{test_target:{'TestTargetID':app_target},unit_target:{'TestTargetID':app_target}}},buildConfigurationList=configs('project-config',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base','zh-Hans'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_target,test_target,unit_target])
def fmt(value, level=0):
    if isinstance(value,dict): return '{\n'+'\n'.join('\t'*(level+1)+json.dumps(k)+' = '+fmt(v,level+1)+';' for k,v in value.items())+'\n'+'\t'*level+'}'
    if isinstance(value,list): return '('+', '.join(fmt(x,level) for x in value)+')'
    return json.dumps(str(value))
project.mkdir(exist_ok=True)
project_file.write_text('// !$*UTF8*$!\n'+fmt({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project_id})+'\n')
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
ref=lambda identifier,name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Seednote.xcodeproj"/>'
(schemes/'Seednote.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2630" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app_target,'Seednote.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test_target,'SeednoteUITests.xctest')}</TestableReference><TestableReference skipped="NO">{ref(unit_target,'SeednoteAppTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'Seednote.app')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Generated', project, 'with',len(sources),'app sources and',len(test_sources),'UI test sources and',len(unit_sources),'app test sources')
