ObjC.import('AppKit');

function run(argv) {
  const pb = $.NSPasteboard.generalPasteboard;
  switch (argv[0]) {
    case 'types':
      return ObjC.deepUnwrap(pb.types).join('\n');
    case 'image': {
      let data = pb.dataForType($.NSPasteboardTypePNG);
      if (data.isNil()) {
        const tiff = pb.dataForType($.NSPasteboardTypeTIFF);
        if (tiff.isNil()) return '';
        data = $.NSBitmapImageRep.imageRepWithData(tiff)
          .representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
      }
      return data.base64EncodedStringWithOptions(0).js;
    }
    case 'files': {
      const urls = pb.readObjectsForClassesOptions(
        $([$.NSURL]), $({ NSPasteboardURLReadingFileURLsOnlyKey: true }));
      return urls.isNil() ? '' : ObjC.deepUnwrap(urls.valueForKey('path')).join('\n');
    }
  }
  throw new Error('usage: types|image|files');
}
