fn main() {
    // macos.mm real del engine (no una copia): el harness prueba el codigo vivo
    let mm = "../../../../engine/rustdesk/src/platform/macos.mm";
    cc::Build::new().flag("-std=c++17").file(mm).compile("macos");
    println!("cargo:rerun-if-changed={}", mm);
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=CoreGraphics");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=IOKit");
    println!("cargo:rustc-link-lib=framework=Security");
    println!("cargo:rustc-link-lib=framework=ApplicationServices");
    println!("cargo:rustc-link-lib=framework=CoreMedia");
    println!("cargo:rustc-link-lib=c++");
    println!("cargo:rustc-link-lib=objc");
}
