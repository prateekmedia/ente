fn main() {
    // Generate Rust scaffolding from the UDL at build time.
    uniffi::generate_scaffolding("src/ensu_uniffi.udl").expect("uniffi scaffolding generation failed");
}
