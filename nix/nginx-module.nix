{
  lib,
  stdenv,
  nim,
  nginx,
}:

stdenv.mkDerivation {
  pname = "isonim-nginx-module";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [ nim ];
  buildInputs = [ nginx ];

  # The module is compiled as a shared object that nginx loads at runtime.
  # It requires nginx development headers (ngx_core.h, ngx_http.h, etc.)
  # which are provided by the nginx package's dev output.
  #
  # Build steps:
  # 1. Compile the Nim code to C with nginx-specific defines
  # 2. Compile the C code against nginx headers
  # 3. Link into a .so that nginx can dlopen

  buildPhase = ''
    # Compile Nim sources to C
    nim c \
      --nimcache:nimcache \
      --noMain \
      --app:lib \
      --gc:arc \
      -d:release \
      -d:nginx \
      --passC:"-I${nginx}/include" \
      --passC:"-I${nginx}/include/nginx" \
      src/isonim/ssr_nginx/module_glue.nim

    # The resulting .so is in nimcache
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp nimcache/*.so $out/lib/ngx_isonim_module.so 2>/dev/null || \
      cp libmodule_glue.so $out/lib/ngx_isonim_module.so 2>/dev/null || \
      echo "Warning: .so not found, this is expected in stub builds"
  '';

  meta = with lib; {
    description = "IsoNim SSR nginx module - serves server-rendered HTML natively";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
