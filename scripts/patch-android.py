"""Small post-`cap add android` tweaks. Every step is optional and never fails the build."""
import os, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent / "android"

def patch(path, fn):
    p = root / path
    if not p.exists():
        print(f"skip (missing): {path}")
        return
    old = p.read_text(encoding="utf-8")
    new = fn(old)
    if new != old:
        p.write_text(new, encoding="utf-8")
        print(f"patched: {path}")

# Resize the window when the on-screen keyboard opens (search / note fields).
def manifest(s):
    if "windowSoftInputMode" not in s:
        s = s.replace("<activity", '<activity\n            android:windowSoftInputMode="adjustResize"', 1)
    return s

patch("app/src/main/AndroidManifest.xml", manifest)

# Human friendly versionName.
BUILD = int(os.environ.get("BUILD_NUMBER", "1") or 1)

def gradle(s):
    # versionCode must grow with every build so Android accepts the APK as an update.
    s = re.sub(r'versionCode\s*=?\s*\d+', f'versionCode {BUILD}', s)
    return re.sub(r'versionName\s*=?\s*"[^"]*"', f'versionName "1.0.{BUILD}"', s)

patch("app/build.gradle", gradle)


# Google sign-in with the Drive scope: the plugin needs MainActivity to forward onActivityResult to it.
MAIN_ACTIVITY = """package app.margins.reader;

import android.content.Intent;
import android.util.Log;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginHandle;
import ee.forgr.capacitor.social.login.GoogleProvider;
import ee.forgr.capacitor.social.login.ModifiedMainActivityForSocialLoginPlugin;
import ee.forgr.capacitor.social.login.SocialLoginPlugin;

public class MainActivity extends BridgeActivity implements ModifiedMainActivityForSocialLoginPlugin {

    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode >= GoogleProvider.REQUEST_AUTHORIZE_GOOGLE_MIN && requestCode < GoogleProvider.REQUEST_AUTHORIZE_GOOGLE_MAX) {
            PluginHandle handle = getBridge().getPlugin("SocialLogin");
            if (handle == null) {
                Log.i("Margins", "SocialLogin plugin handle is null");
                return;
            }
            Plugin plugin = handle.getInstance();
            if (!(plugin instanceof SocialLoginPlugin)) {
                Log.i("Margins", "SocialLogin plugin instance has the wrong type");
                return;
            }
            ((SocialLoginPlugin) plugin).handleGoogleLoginIntent(requestCode, data);
        }
    }

    @Override
    public void IHaveModifiedTheMainActivityForTheUseWithSocialLoginPlugin() {}
}
"""

def main_activity():
    java = root / "app/src/main/java/app/margins/reader"
    if not (root / "app").exists():
        print("skip (missing): MainActivity")
        return
    java.mkdir(parents=True, exist_ok=True)
    (java / "MainActivity.java").write_text(MAIN_ACTIVITY, encoding="utf-8")
    print("patched: MainActivity.java")

main_activity()


# Sign every build with the key stored in the repository (keystore/debug.keystore).
# Without this, Gradle makes a brand-new random debug key on each CI run, so the signing fingerprint changes
# every build and Google sign-in (which checks that fingerprint) stops working after each update.
def signing(s):
    if "margins-fixed-key" in s:
        return s
    ks = (root.parent / "keystore" / "debug.keystore").as_posix()
    block = (
        "\n    // margins-fixed-key\n"
        "    signingConfigs {\n"
        "        debug {\n"
        f"            storeFile file('{ks}')\n"
        "            storePassword 'android'\n"
        "            keyAlias 'androiddebugkey'\n"
        "            keyPassword 'android'\n"
        "        }\n"
        "    }\n"
    )
    return re.sub(r"(\nandroid\s*\{)", lambda m: m.group(1) + block, s, count=1)

patch("app/build.gradle", signing)


# Launcher icon: charcoal tile + snow M, with a monochrome layer so Android 13+ "themed icons" tint it
# like every other app. Written independently of what capacitor-assets generated (it is only a fallback for old Androids).
def adaptive_icon():
    res = root / "app/src/main/res"
    assets = root.parent / "assets"
    if not res.exists():
        print("skip (missing): res")
        return
    import shutil
    nodpi = res / "drawable-nodpi"
    nodpi.mkdir(parents=True, exist_ok=True)
    for src, dst in (("icon-foreground.png", "margins_ic_fg.png"), ("icon-background.png", "margins_ic_bg.png"), ("icon-monochrome.png", "margins_ic_mono.png")):
        if not (assets / src).exists():
            print(f"skip (missing asset): {src}")
            return
        shutil.copyfile(assets / src, nodpi / dst)
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/margins_ic_bg"/>\n'
        '    <foreground android:drawable="@drawable/margins_ic_fg"/>\n'
        '    <monochrome android:drawable="@drawable/margins_ic_mono"/>\n'
        '</adaptive-icon>\n'
    )
    d = res / "mipmap-anydpi-v26"
    d.mkdir(parents=True, exist_ok=True)
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (d / name).write_text(xml, encoding="utf-8")
    print("patched: adaptive launcher icon (with monochrome layer)")

try:
    adaptive_icon()
except Exception as e:
    print("skip (icon):", e)
