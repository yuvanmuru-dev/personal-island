"""Generate the controlled, explicit-source Xcode project. No upstream scripts."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

if __package__:
    from . import app_policy
else:
    import app_policy

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "PersonalIslandApp"
PROJECT = APP / "PersonalIsland.xcodeproj"
APP_FILES = [
    "PersonalIslandApp.swift", "IslandCoordinator.swift", "IslandPanelController.swift",
    "IslandGeometry.swift", "IslandView.swift", "SettingsView.swift", "NotchShape.swift",
    "IslandPresentation.swift", "CaptureGeometry.swift", "CaptureFlow.swift", "GlobalHotKey.swift",
    "RegionSelector.swift", "ScreenRegionCapture.swift", "ShelfDragFlow.swift", "ShelfDragSource.swift",
    "WindowPicker.swift", "IslandSettings.swift", "SpotifyPlayback.swift", "SpotifyAdapter.swift", "SpotifyArtwork.swift",
    "CalendarAgenda.swift", "CalendarAdapter.swift", "BatteryStatus.swift", "BatteryAdapter.swift", "IslandTimers.swift",
]
CORE_FILES = ["Models.swift", "OwnedExportDirectory.swift", "ShelfStore.swift"]
RESOURCES = ["Atoll-LICENSE.txt", "Atoll-NOTICE.txt", "Atoll-COPYRIGHT_ASSETS.txt", "Atoll-TRADEMARKS.txt"]


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def serialize(value, indent=0):
    if isinstance(value, dict):
        lines = ["{"]
        for key, entry in value.items():
            lines.append("\t" * (indent + 1) + json.dumps(key) + " = " + serialize(entry, indent + 1) + ";")
        return "\n".join(lines) + "\n" + "\t" * indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + serialize(entry, indent + 1) + ",\n" for entry in value) + "\t" * indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value))


def main():
    APP.mkdir(exist_ok=True)
    resources = APP / "Resources"
    resources.mkdir(exist_ok=True)
    # Notices are checked-in source resources. A fresh checkout must build
    # without downloading the separate upstream audit archive.
    for name in RESOURCES:
        if not (resources / name).is_file():
            raise FileNotFoundError("Required retained notice is missing: " + name)
    info = {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Personal Island", "CFBundleDisplayName": "Personal Island",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.8.0",
        "CFBundleVersion": "13", "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
        "LSUIElement": True, "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "NSHumanReadableCopyright": "Personal local build. Includes attributed Atoll/boring.notch presentation code.",
        **app_policy.REQUIRED_INFO_STRINGS,
    }
    (APP / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
    (APP / "PersonalIsland.entitlements").write_bytes(plistlib.dumps(app_policy.RELEASE_ENTITLEMENTS, sort_keys=True))
    objects = {}

    def add(object_key, isa, **fields):
        key = identifier(object_key)
        objects[key] = {"isa": isa, **fields}
        return key

    app_refs, app_builds = [], []
    for name in APP_FILES:
        ref = add("app-ref:" + name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=name, sourceTree="<group>")
        app_refs.append(ref)
        app_builds.append(add("app-build:" + name, "PBXBuildFile", fileRef=ref))
    core_refs, core_builds = [], []
    for name in CORE_FILES:
        ref = add("core-ref:" + name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=name, sourceTree="<group>")
        core_refs.append(ref)
        core_builds.append(add("core-build:" + name, "PBXBuildFile", fileRef=ref))
    resource_refs, resource_builds = [], []
    for name in RESOURCES:
        ref = add("resource-ref:" + name, "PBXFileReference", lastKnownFileType="text", path=name, sourceTree="<group>")
        resource_refs.append(ref)
        resource_builds.append(add("resource-build:" + name, "PBXBuildFile", fileRef=ref))
    app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="PersonalIsland.app", sourceTree="BUILT_PRODUCTS_DIR")
    core_product = add("core-product", "PBXFileReference", explicitFileType="wrapper.framework", includeInIndex=0, path="PersonalIslandCore.framework", sourceTree="BUILT_PRODUCTS_DIR")
    info_ref = add("info-ref", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>")
    entitlements_ref = add("entitlements-ref", "PBXFileReference", lastKnownFileType="text.plist.entitlements", path="PersonalIsland.entitlements", sourceTree="<group>")
    app_group = add("app-group", "PBXGroup", children=app_refs, path="Sources", sourceTree="<group>")
    core_group = add("core-group", "PBXGroup", children=core_refs, name="PersonalIslandCore (local source)", path="../PersonalIslandCore/Sources/PersonalIslandCore", sourceTree="<group>")
    resource_group = add("resources-group", "PBXGroup", children=resource_refs, path="Resources", sourceTree="<group>")
    product_group = add("products-group", "PBXGroup", children=[app_product, core_product], name="Products", sourceTree="<group>")
    main_group = add("main-group", "PBXGroup", children=[app_group, core_group, resource_group, info_ref, entitlements_ref, product_group], sourceTree="<group>")
    app_sources = add("app-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=app_builds, runOnlyForDeploymentPostprocessing=0)
    core_sources = add("core-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=core_builds, runOnlyForDeploymentPostprocessing=0)
    app_resources = add("app-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
    core_resources = add("core-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    core_link = add("core-link", "PBXBuildFile", fileRef=core_product)
    app_frameworks = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[core_link], runOnlyForDeploymentPostprocessing=0)
    core_frameworks = add("core-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    common = {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.2", "SWIFT_VERSION": "6.0",
        "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "ARCHS": "arm64", "SUPPORTED_PLATFORMS": "macosx",
        "CLANG_MODULE_CACHE_PATH": "$(PROJECT_DIR)/../build/ModuleCache",
    }
    app_settings = {
        "PRODUCT_NAME": "PersonalIsland", "PRODUCT_BUNDLE_IDENTIFIER": "dev.personal.PersonalIsland",
        "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "PersonalIsland.entitlements", "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": "", "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": "NO", "ENABLE_RESOURCE_ACCESS_CAMERA": "NO",
        "ENABLE_RESOURCE_ACCESS_CONTACTS": "NO", "ENABLE_RESOURCE_ACCESS_CALENDARS": "NO",
        "ENABLE_RESOURCE_ACCESS_LOCATION": "NO", "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": "NO",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(BUILT_PRODUCTS_DIR)"],
        "SWIFT_EMIT_LOC_STRINGS": "NO", "DEAD_CODE_STRIPPING": "YES",
    }
    core_settings = {
        "PRODUCT_NAME": "PersonalIslandCore", "PRODUCT_BUNDLE_IDENTIFIER": "dev.personal.PersonalIslandCore",
        "PRODUCT_MODULE_NAME": "PersonalIslandCore", "DEFINES_MODULE": "YES",
        "MACH_O_TYPE": "staticlib", "SKIP_INSTALL": "YES", "GENERATE_INFOPLIST_FILE": "YES",
        "CODE_SIGNING_ALLOWED": "NO", "SWIFT_INSTALL_OBJC_HEADER": "NO",
    }

    def configuration_list(name, base):
        configs = []
        for kind in ("Debug", "Release"):
            settings = {**base, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if kind == "Debug" else "-O"}
            if kind == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            if kind == "Debug" and name == "app-config":
                settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "YES"
            configs.append(add(name + ":" + kind, "XCBuildConfiguration", buildSettings=settings, name=kind))
        return add(name + ":list", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    project_configs = configuration_list("project-config", common)
    core_configs = configuration_list("core-config", core_settings)
    app_configs = configuration_list("app-config", app_settings)
    core_target = add("core-target", "PBXNativeTarget", buildConfigurationList=core_configs, buildPhases=[core_sources, core_frameworks, core_resources], buildRules=[], dependencies=[], name="PersonalIslandCore", productName="PersonalIslandCore", productReference=core_product, productType="com.apple.product-type.framework")
    proxy = add("core-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1, remoteGlobalIDString=core_target, remoteInfo="PersonalIslandCore")
    dependency = add("core-dependency", "PBXTargetDependency", target=core_target, targetProxy=proxy)
    app_target = add("app-target", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[app_sources, app_frameworks, app_resources], buildRules=[], dependencies=[dependency], name="PersonalIsland", productName="PersonalIsland", productReference=app_product, productType="com.apple.product-type.application")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2720"}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[app_target, core_target])
    PROJECT.mkdir(exist_ok=True)
    root = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": identifier("project")}
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(root) + "\n")
    scheme = ET.Element("Scheme", LastUpgradeVersion="2720", version="1.3")
    action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entry = ET.SubElement(ET.SubElement(action, "BuildActionEntries"), "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")

    def reference(parent):
        return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=app_target, BuildableName="PersonalIsland.app", BlueprintName="PersonalIsland", ReferencedContainer="container:PersonalIsland.xcodeproj")

    reference(entry)
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="NO")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    scheme_path = PROJECT / "xcshareddata/xcschemes/PersonalIsland.xcscheme"
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(scheme_path, encoding="UTF-8", xml_declaration=True)
    print("Generated explicit-source PersonalIsland Xcode project; no remote packages or build scripts.")


if __name__ == "__main__":
    main()
