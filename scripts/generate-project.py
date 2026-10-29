"""Regenerate the checked-in Xcode project after adding Swift files."""
from pathlib import Path
import hashlib, plistlib, json
root = Path(__file__).resolve().parents[1]
objects = {}
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key, **value):
    objects[uid(key)] = value
    return uid(key)
sources = []
def filegroup(key, path):
    children = []
    for f in sorted((root / path).glob('*.swift')):
        ref = add(str(f.relative_to(root)), isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=f.name, sourceTree='<group>')
        children.append(ref)
        sources.append(add('build:' + str(f.relative_to(root)), isa='PBXBuildFile', fileRef=ref))
    return add(key, isa='PBXGroup', path=path, sourceTree='<group>', children=children)
app = filegroup('app', 'App')
core = filegroup('core', 'Sources/TaskCore')
assets = add('assets', isa='PBXFileReference', lastKnownFileType='folder.assetcatalog', path='Assets.xcassets', sourceTree='<group>')
privacy = add('privacy', isa='PBXFileReference', lastKnownFileType='text.xml', path='PrivacyInfo.xcprivacy', sourceTree='<group>')
objects[app]['children'] += [assets, privacy]
resources = [add('build:' + key, isa='PBXBuildFile', fileRef=ref) for key, ref in [('assets', assets), ('privacy', privacy)]]
product = add('product', isa='PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path='ThreeDays.app', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', isa='PBXGroup', name='Products', children=[product], sourceTree='<group>')
main = add('main', isa='PBXGroup', children=[app, core, products], sourceTree='<group>')
phases = [add('sources', isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=sources, runOnlyForDeploymentPostprocessing='0'), add('frameworks', isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0'), add('resources', isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=resources, runOnlyForDeploymentPostprocessing='0')]
projectConfigs, targetConfigs = [], []
for mode in ['Debug', 'Release']:
    common = {'ALWAYS_SEARCH_USER_PATHS':'NO', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES', 'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'GCC_C_LANGUAGE_STANDARD':'gnu17', 'DEBUG_INFORMATION_FORMAT':'dwarf' if mode == 'Debug' else 'dwarf-with-dsym', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode == 'Debug' else '-O'}
    if mode == 'Debug': common.update({'ENABLE_TESTABILITY':'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG $(inherited)', 'ONLY_ACTIVE_ARCH':'YES'})
    projectConfigs.append(add('project:' + mode, isa='XCBuildConfiguration', name=mode, buildSettings=common))
    settings = {'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor', 'CODE_SIGN_STYLE':'Automatic', 'CURRENT_PROJECT_VERSION':'1', 'GENERATE_INFOPLIST_FILE':'YES', 'INFOPLIST_KEY_CFBundleDisplayName':'3日間タスク', 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption':'NO', 'INFOPLIST_KEY_LSApplicationCategoryType':'public.app-category.productivity', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES', 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait', 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', 'INFOPLIST_KEY_UIRequiresFullScreen':'NO', 'LD_RUNPATH_SEARCH_PATHS':['$(inherited)', '@executable_path/Frameworks'], 'MARKETING_VERSION':'0.2.0', 'PRODUCT_BUNDLE_IDENTIFIER':'io.github.reiji55.threedays', 'PRODUCT_NAME':'$(TARGET_NAME)', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO', 'TARGETED_DEVICE_FAMILY':'1,2', 'SWIFT_EMIT_LOC_STRINGS':'YES'}
    targetConfigs.append(add('target:' + mode, isa='XCBuildConfiguration', name=mode, buildSettings=settings))
pConfig = add('projectConfig', isa='XCConfigurationList', buildConfigurations=projectConfigs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
tConfig = add('targetConfig', isa='XCConfigurationList', buildConfigurations=targetConfigs, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
target = add('target', isa='PBXNativeTarget', buildConfigurationList=tConfig, buildPhases=phases, buildRules=[], dependencies=[], name='ThreeDays', productName='ThreeDays', productReference=product, productType='com.apple.product-type.application')
project = add('project', isa='PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastSwiftUpdateCheck':'1600', 'LastUpgradeCheck':'1600', 'TargetAttributes':{target:{'CreatedOnToolsVersion':'16.0'}}}, buildConfigurationList=pConfig, compatibilityVersion='Xcode 14.0', developmentRegion='ja', hasScannedForEncodings='0', knownRegions=['ja','en','Base'], mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
with (root/'ThreeDays.xcodeproj/project.pbxproj').open('wb') as f:
    plistlib.dump({'archiveVersion':'1', 'classes':{}, 'objectVersion':'56', 'objects':objects, 'rootObject':project}, f, sort_keys=False)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="ThreeDays.app" BlueprintName="ThreeDays" ReferencedContainer="container:ThreeDays.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(root/'ThreeDays.xcodeproj/xcshareddata/xcschemes/ThreeDays.xcscheme').write_text(scheme)
print(f'Project generated: {len(sources)} Swift source files')
