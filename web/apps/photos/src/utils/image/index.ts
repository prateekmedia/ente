// these utils only work in env where OffscreenCanvas is available

import { BlobOptions, Dimensions } from "types/image";
import { enlargeBox } from "utils/machineLearning";
import { Box } from "../../../thirdparty/face-api/classes";

export function normalizePixelBetween0And1(pixelValue: number) {
    return pixelValue / 255.0;
}

export function readPixelColor(
    imageData: Uint8ClampedArray,
    width: number,
    height: number,
    x: number,
    y: number,
) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
        return { r: 0, g: 0, b: 0, a: 0 };
    }
    const index = (y * width + x) * 4;
    return {
        r: imageData[index],
        g: imageData[index + 1],
        b: imageData[index + 2],
        a: imageData[index + 3],
    };
}

export function clamp(value: number, min: number, max: number) {
    return Math.min(max, Math.max(min, value));
}

/// Returns the pixel value (RGB) at the given coordinates using bilinear interpolation.
export function getPixelBilinear(
    fx: number,
    fy: number,
    imageData: Uint8ClampedArray,
    imageWidth: number,
    imageHeight: number,
) {
    // Clamp to image boundaries
    fx = clamp(fx, 0, imageWidth - 1);
    fy = clamp(fy, 0, imageHeight - 1);

    // Get the surrounding coordinates and their weights
    const x0 = Math.floor(fx);
    const x1 = Math.ceil(fx);
    const y0 = Math.floor(fy);
    const y1 = Math.ceil(fy);
    const dx = fx - x0;
    const dy = fy - y0;
    const dx1 = 1.0 - dx;
    const dy1 = 1.0 - dy;

    // Get the original pixels
    const pixel1 = readPixelColor(imageData, imageWidth, imageHeight, x0, y0);
    const pixel2 = readPixelColor(imageData, imageWidth, imageHeight, x1, y0);
    const pixel3 = readPixelColor(imageData, imageWidth, imageHeight, x0, y1);
    const pixel4 = readPixelColor(imageData, imageWidth, imageHeight, x1, y1);

    function bilinear(val1: number, val2: number, val3: number, val4: number) {
        return Math.round(
            val1 * dx1 * dy1 +
                val2 * dx * dy1 +
                val3 * dx1 * dy +
                val4 * dx * dy,
        );
    }

    // Interpolate the pixel values
    const red = bilinear(pixel1.r, pixel2.r, pixel3.r, pixel4.r);
    const green = bilinear(pixel1.g, pixel2.g, pixel3.g, pixel4.g);
    const blue = bilinear(pixel1.b, pixel2.b, pixel3.b, pixel4.b);

    return { r: red, g: green, b: blue };
}

export function resizeToSquare(img: ImageBitmap, size: number) {
    const scale = size / Math.max(img.height, img.width);
    const width = scale * img.width;
    const height = scale * img.height;
    const offscreen = new OffscreenCanvas(size, size);
    const ctx = offscreen.getContext("2d");
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(img, 0, 0, width, height);
    const resizedImage = offscreen.transferToImageBitmap();
    return { image: resizedImage, width, height };
}

export function transform(
    imageBitmap: ImageBitmap,
    affineMat: number[][],
    outputWidth: number,
    outputHeight: number,
) {
    const offscreen = new OffscreenCanvas(outputWidth, outputHeight);
    const context = offscreen.getContext("2d");
    context.imageSmoothingQuality = "high";

    context.transform(
        affineMat[0][0],
        affineMat[1][0],
        affineMat[0][1],
        affineMat[1][1],
        affineMat[0][2],
        affineMat[1][2],
    );

    context.drawImage(imageBitmap, 0, 0);
    return offscreen.transferToImageBitmap();
}

export function crop(imageBitmap: ImageBitmap, cropBox: Box, size: number) {
    const dimensions: Dimensions = {
        width: size,
        height: size,
    };

    return cropWithRotation(imageBitmap, cropBox, 0, dimensions, dimensions);
}

export function cropWithRotation(
    imageBitmap: ImageBitmap,
    cropBox: Box,
    rotation?: number,
    maxSize?: Dimensions,
    minSize?: Dimensions,
) {
    const box = cropBox.round();

    const outputSize = { width: box.width, height: box.height };
    if (maxSize) {
        const minScale = Math.min(
            maxSize.width / box.width,
            maxSize.height / box.height,
        );
        if (minScale < 1) {
            outputSize.width = Math.round(minScale * box.width);
            outputSize.height = Math.round(minScale * box.height);
        }
    }

    if (minSize) {
        const maxScale = Math.max(
            minSize.width / box.width,
            minSize.height / box.height,
        );
        if (maxScale > 1) {
            outputSize.width = Math.round(maxScale * box.width);
            outputSize.height = Math.round(maxScale * box.height);
        }
    }

    // addLogLine({ imageBitmap, box, outputSize });

    const offscreen = new OffscreenCanvas(outputSize.width, outputSize.height);
    const offscreenCtx = offscreen.getContext("2d");
    offscreenCtx.imageSmoothingQuality = "high";

    offscreenCtx.translate(outputSize.width / 2, outputSize.height / 2);
    rotation && offscreenCtx.rotate(rotation);

    const outputBox = new Box({
        x: -outputSize.width / 2,
        y: -outputSize.height / 2,
        width: outputSize.width,
        height: outputSize.height,
    });

    const enlargedBox = enlargeBox(box, 1.5);
    const enlargedOutputBox = enlargeBox(outputBox, 1.5);

    offscreenCtx.drawImage(
        imageBitmap,
        enlargedBox.x,
        enlargedBox.y,
        enlargedBox.width,
        enlargedBox.height,
        enlargedOutputBox.x,
        enlargedOutputBox.y,
        enlargedOutputBox.width,
        enlargedOutputBox.height,
    );

    return offscreen.transferToImageBitmap();
}

export function addPadding(image: ImageBitmap, padding: number) {
    const scale = 1 + padding * 2;
    const width = scale * image.width;
    const height = scale * image.height;
    const offscreen = new OffscreenCanvas(width, height);
    const ctx = offscreen.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(
        image,
        width / 2 - image.width / 2,
        height / 2 - image.height / 2,
        image.width,
        image.height,
    );

    return offscreen.transferToImageBitmap();
}

export async function imageBitmapToBlob(
    imageBitmap: ImageBitmap,
    options?: BlobOptions,
) {
    const offscreen = new OffscreenCanvas(
        imageBitmap.width,
        imageBitmap.height,
    );
    offscreen.getContext("2d").drawImage(imageBitmap, 0, 0);

    return offscreen.convertToBlob(options);
}

export async function imageBitmapFromBlob(blob: Blob) {
    return createImageBitmap(blob);
}
