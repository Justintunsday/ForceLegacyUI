#!/usr/bin/env python3
"""Generate the checked-in Xcode project with only Python's standard library."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]

def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value))

def generate():
    objects = {}
    def add(key, body):
        identifier = uid(key)
        objects[identifier] = body
        return identifier
    refs = {}
    sources = sorted(str(p.relative_to(ROOT)).replace("\\", "/") for p in (ROOT / "ForceLegacyUI").rglob("*")
                     if p.suffix in (".swift", ".m", ".h"))
    other = ["ForceLegacyUI/Resources/Info.plist", "ForceLegacyUI/Resources/ForceLegacyUI.entitlements", "ForceLegacyUI/Resources/HouseArrest.entitlements", "Config/Project.xcconfig",
             "Probes/Modern-Info.plist", "Probes/Legacy-Info.plist", "Packages/LegacyCore/Package.swift", "Probes/CompatibilityProbe.swift"]
    kinds = {".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h", ".plist": "text.plist.xml",
             ".entitlements": "text.plist.entitlements", ".xcconfig": "text.xcconfig"}
    for path in sources + other + ["ForceLegacyUI/Resources/Assets.xcassets"]:
        refs[path] = add("file:" + path, f'isa = PBXFileReference; lastKnownFileType = {kinds.get(Path(path).suffix, "folder.assetcatalog")}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    package = add("package", 'isa = XCLocalSwiftPackageReference; relativePath = Packages/LegacyCore;')
    product = add("package-product", f'isa = XCSwiftPackageProductDependency; package = {package}; productName = LegacyCore;')
    targets = []
    products = []
    product_refs = {}
    target_names = ["ForceLegacyUI", "CompatibilityProbeModern", "CompatibilityProbeLegacy"]
    bridge_sources = [p for p in sources if p.endswith(".m")]
    for name in target_names:
        is_app = name == "ForceLegacyUI"
        product_ref = add("app:" + name, f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR;')
        products.append(product_ref); product_refs[name] = product_ref
        target_sources = [p for p in sources if p.endswith((".swift", ".m"))] if is_app else bridge_sources + ["Probes/CompatibilityProbe.swift"]
        compiled = [add("compile:" + name + p, f'isa = PBXBuildFile; fileRef = {refs[p]};') for p in target_sources]
        source_phase = add("sources:" + name, 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ",".join(compiled) + '); runOnlyForDeploymentPostprocessing = 0;')
        asset = add("asset:" + name, f'isa = PBXBuildFile; fileRef = {refs["ForceLegacyUI/Resources/Assets.xcassets"]};')
        resources = add("resources:" + name, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({asset}); runOnlyForDeploymentPostprocessing = 0;')
        linked = add("link:" + name, f'isa = PBXBuildFile; productRef = {product};') if is_app else None
        frameworks = add("frameworks:" + name, 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (' + (linked or "") + '); runOnlyForDeploymentPostprocessing = 0;')
        configs = []
        for config in ["Debug", "Release"]:
            plist = "ForceLegacyUI/Resources/Info.plist" if is_app else ("Probes/Legacy-Info.plist" if name.endswith("Legacy") else "Probes/Modern-Info.plist")
            bundle = "$(FL_BUNDLE_ID)" + ("" if is_app else (".probe.legacy" if name.endswith("Legacy") else ".probe.modern"))
            settings = {"PRODUCT_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": bundle, "INFOPLIST_FILE": plist,
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if config == "Debug" else "",
                        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"}
            if is_app:
                settings["CODE_SIGN_ENTITLEMENTS"] = "ForceLegacyUI/Resources/ForceLegacyUI.entitlements"
            setting_text = " ".join(f'{key} = {q(value)};' for key, value in settings.items())
            configs.append(add("config:" + name + config, f'isa = XCBuildConfiguration; baseConfigurationReference = {refs["Config/Project.xcconfig"]}; buildSettings = {{ {setting_text} }}; name = {config};'))
        config_list = add("configs:" + name, 'isa = XCConfigurationList; buildConfigurations = (' + ",".join(configs) + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
        target = add("target:" + name, f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = ({source_phase},{frameworks},{resources}); buildRules = (); dependencies = (); name = {name}; packageProductDependencies = (' + (product if is_app else "") + f'); productName = {name}; productReference = {product_ref}; productType = "com.apple.product-type.application";')
        targets.append(target)
    products_group = add("products", 'isa = PBXGroup; children = (' + ",".join(products) + '); name = Products; sourceTree = "<group>";')
    group = add("group", 'isa = PBXGroup; children = (' + ",".join(list(refs.values()) + [products_group]) + '); sourceTree = "<group>";')
    project_configs = [add("project:" + name, f'isa = XCBuildConfiguration; buildSettings = {{ }}; name = {name};') for name in ["Debug", "Release"]]
    config_list = add("project-configs", 'isa = XCConfigurationList; buildConfigurations = (' + ",".join(project_configs) + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    project = add("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; TargetAttributes = {{ {targets[0]} = {{ SystemCapabilities = {{ com.apple.ApplicationGroups.iOS = {{ enabled = 1; }}; }}; }}; }}; }}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {group}; packageReferences = ({package}); productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = (' + ",".join(targets) + ');')
    pbx = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'
    pbx += "\n".join(f"\t{identifier} = {{ {body} }};" for identifier, body in sorted(objects.items()))
    pbx += f'\n}}; rootObject = {project}; }}\n'
    generated = {ROOT / "ForceLegacyUI.xcodeproj/project.pbxproj": pbx}
    for scheme_name, name in [(n, n) for n in target_names] + [("ForceLegacyUIDevice", "ForceLegacyUI")]:
        target = uid("target:" + name)
        build_names = target_names if scheme_name == "ForceLegacyUI" else [name]
        entries = "".join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:" + n)}" BuildableName="{n}.app" BlueprintName="{n}" ReferencedContainer="container:ForceLegacyUI.xcodeproj"/></BuildActionEntry>' for n in build_names)
        runnable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:ForceLegacyUI.xcodeproj"/>'
        scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{runnable}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{runnable}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
        generated[ROOT / f"ForceLegacyUI.xcodeproj/xcshareddata/xcschemes/{scheme_name}.xcscheme"] = scheme
    return generated

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--check", action="store_true"); args = parser.parse_args()
    stale = []
    for path, content in generate().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content: stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content, encoding="utf-8", newline="\n")
    if stale: raise SystemExit("Regenerate project: " + ", ".join(stale))
    print("Xcode project is current." if args.check else "Generated Xcode project and shared schemes.")
