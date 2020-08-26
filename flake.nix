{
  description = "Build npm and yarn packages";

  outputs = { self }: {
    overlay = final: prev: final.callPackage ./. { };
  };
}
