{ mkDerivation, aeson, base, blaze-builder, bytestring
, case-insensitive, conduit, conduit-extra, connection, cookie
, data-default-class, exceptions, hspec, http-client
, http-client-tls, http-types, HUnit, lifted-base, monad-control
, mtl, network, resourcet, stdenv, streaming-commons, temporary
, text, time, transformers, utf8-string, wai, wai-conduit, warp
, warp-tls
}:
mkDerivation {
  pname = "http-conduit";
  version = "2.2.3";
  sha256 = "1hqdzrr7vr2ylfjj61hayy9havhj5r2mym21815vzcvnzs01xrgf";
  libraryHaskellDepends = [
    aeson base bytestring conduit conduit-extra exceptions http-client
    http-client-tls http-types lifted-base monad-control mtl resourcet
    transformers
  ];
  testHaskellDepends = [
    aeson base blaze-builder bytestring case-insensitive conduit
    conduit-extra connection cookie data-default-class hspec
    http-client http-types HUnit lifted-base network resourcet
    streaming-commons temporary text time transformers utf8-string wai
    wai-conduit warp warp-tls
  ];
  doCheck = false;
  homepage = "http://www.yesodweb.com/book/http-conduit";
  description = "HTTP client package with conduit interface and HTTPS support";
  license = stdenv.lib.licenses.bsd3;
}
