use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out = Command::new("nasm").arg("-v").output();
    match out {
        Ok(o) if o.status.success() => {
            let v = String::from_utf8_lossy(&o.stdout).trim().to_string();
            println!("cargo:warning=nasm on PATH: {v}");
            if !v.contains("version 3.02") {
                panic!("nasm-probe: expected NASM 3.02, got: {v}");
            }
        }
        Ok(o) => panic!("nasm-probe: nasm -v exited {}", o.status),
        Err(e) => panic!("nasm-probe: nasm not found on PATH: {e}"),
    }
}
