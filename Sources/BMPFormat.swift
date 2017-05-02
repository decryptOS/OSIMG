// 
// BMPFormat.swift
// OSIMG
// 
// Created by Johannes Roth on 29.04.2017.
// 
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
// 
//   http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
// 

#if os(Linux)
    import Glibc
#elseif os(macOS)
    import Darwin
#endif

public enum BMPError: Error {
    case incorrectFileHeader
    case incorrectInfoHeader
    case badColorTable
    case unsupportedCompression(Int)
    case unsupportedBitCount(Int)
}

internal extension Image {
    internal convenience init(bmpFile: String) throws {
        // Open file
        let file = fopen(bmpFile, "rb")
        if file == nil { throw ImageError.fileNotFound }
        defer { fclose(file) }

        let fileHeader = UnsafeMutableRawPointer.allocate(bytes: 14, alignedTo: MemoryLayout<UInt8>.alignment)
        defer { fileHeader.deallocate(bytes: 14, alignedTo: MemoryLayout<UInt8>.alignment) }

        // Read BMP header
        if fread(fileHeader, 1, 14, file) != 14 { throw BMPError.incorrectFileHeader }
        
        let firstTwoBytes = fileHeader.bindMemory(to: UInt8.self, capacity: 2)

        // Check if the first two bytes in header are the characters 'B' and 'M'
        if (firstTwoBytes[0] != 0x42 /* B */) || (firstTwoBytes[1] != 0x4D /* M */) { throw BMPError.incorrectFileHeader }

        var dataOffset = Int(unsafeBitCast(fileHeader.advanced(by: 0x0A), to: UnsafeMutablePointer<UInt32>.self).pointee)

        var headerSize: UInt32 = 0
        try withUnsafePointer(to: &headerSize) { pointer in
            if fread(UnsafeMutableRawPointer(mutating: pointer), 4, 1, file) != 1 {
                throw BMPError.incorrectInfoHeader
            }
        }

        fseek(file, -4, SEEK_CUR)

        let infoHeader = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(headerSize))
        defer { infoHeader.deallocate(capacity: Int(headerSize)) }

        if fread(infoHeader, 1, Int(headerSize), file) != Int(headerSize) { throw BMPError.incorrectInfoHeader }

        let width             = Int(unsafeBitCast(infoHeader.advanced(by: 0x12 - 0x0E), to: UnsafeMutablePointer<Int32>.self).pointee)
        var height            = Int(unsafeBitCast(infoHeader.advanced(by: 0x16 - 0x0E), to: UnsafeMutablePointer<Int32>.self).pointee)

        let planes            = Int(unsafeBitCast(infoHeader.advanced(by: 0x1A - 0x0E), to: UnsafeMutablePointer<UInt16>.self).pointee)
        let bitCount          = Int(unsafeBitCast(infoHeader.advanced(by: 0x1C - 0x0E), to: UnsafeMutablePointer<UInt16>.self).pointee)
        let compression       = Int(unsafeBitCast(infoHeader.advanced(by: 0x1E - 0x0E), to: UnsafeMutablePointer<UInt32>.self).pointee)
        var imageSize         = Int(unsafeBitCast(infoHeader.advanced(by: 0x22 - 0x0E), to: UnsafeMutablePointer<UInt32>.self).pointee)

        let verticalFlipped   = height < 0

        if verticalFlipped { height = -height }

        assert(planes == 1)
        assert(compression == 0)

        let pixelSize: Int

        switch bitCount {
        case 16:          pixelSize = 2
        case 24:          pixelSize = 3
        case 1, 4, 8, 32: pixelSize = 4
        default:          throw BMPError.unsupportedBitCount(bitCount)
        }

        var bytesPerRow: Int

        switch compression {
        case 0: // BI_RGB
            bytesPerRow = width * pixelSize
            while bytesPerRow % 4 != 0 { bytesPerRow += 1 }
        default:
            throw BMPError.unsupportedCompression(compression)
        }

        // Some BMP files are misformatted, guess missing information
        if imageSize == 0 { imageSize = bytesPerRow * height }
        if dataOffset == 0 { dataOffset = Int(headerSize) + 14 } // Data starts immediately after the header

        var colorTableEntries = Int(unsafeBitCast(infoHeader.advanced(by: 0x2E - 0x0E), to: UnsafeMutablePointer<UInt32>.self).pointee)

        let colorMask: ColorMask

        var data: UnsafeMutablePointer<UInt8>

        if (bitCount == 1) || (bitCount == 2) || (bitCount == 8) {
            if colorTableEntries == 0 {
                colorTableEntries = _pow(2, bitCount)
            }

            // Allocate memory to store color table
            let colorTablePointer = UnsafeMutablePointer<UInt32>.allocate(capacity: colorTableEntries)
            defer { colorTablePointer.deallocate(capacity: colorTableEntries) }

            // Read color table
            if fread(colorTablePointer, 4, colorTableEntries, file) != colorTableEntries { throw BMPError.badColorTable }
            
            // Allocate memory to store indexed image data
            let indexedData = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)
            defer { indexedData.deallocate(capacity: imageSize) }

            fseek(file, dataOffset, SEEK_SET)
            fread(indexedData, 1, imageSize, file)

            data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)

            let data32 = unsafeBitCast(data, to: UnsafeMutablePointer<UInt32>.self)

            switch bitCount {
            case 1, 4, 8:
                for i in 0 ..< imageSize {
                    let colorIndex = Int(indexedData.advanced(by: i).pointee)
                    let color32 = colorTablePointer.advanced(by: colorIndex).pointee
                    data32.advanced(by: i).pointee = color32
                }

                colorMask = ColorMask(red: 0x00FF0000, green: 0x0000FF00, blue: 0x000000FF, alpha: 0x00000000, redShift: 16, greenShift: 8, blueShift: 0, alphaShift: 0)

            default:
                throw BMPError.unsupportedBitCount(bitCount)
            }
        } else {
            switch bitCount {
            case 16: // 5 bit per color channel, 1 bit unused
                colorMask = ColorMask(red: 0x00007C00, green: 0x000003E0, blue: 0x0000001F, alpha: 0x00000000, redShift: 10, greenShift: 5, blueShift: 0, alphaShift: 0)

                data = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)
                
                fseek(file, dataOffset, SEEK_SET)
                fread(data, 1, imageSize, file)

            case 24: // 3 bytes pixelSize
                colorMask = ColorMask(red: 0x00FF0000, green: 0x0000FF00, blue: 0x000000FF, alpha: 0x00000000, redShift: 16, greenShift: 8, blueShift: 0, alphaShift: 0)

                var paddedBytesPerRow = width * 3
                while paddedBytesPerRow % 4 != 0 { paddedBytesPerRow += 1 }

                bytesPerRow = width * 3
                imageSize = width * height * pixelSize

                data = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)

                let lineData = UnsafeMutablePointer<UInt8>.allocate(capacity: paddedBytesPerRow)
                defer { lineData.deallocate(capacity: paddedBytesPerRow) }

                fseek(file, dataOffset, SEEK_SET)
                for row in 0 ..< height {
                    fread(lineData, 1, paddedBytesPerRow, file)

                    for p in 0 ..< width * 3 {
                        data[row * width * 3 + p] = lineData[p]
                    }
                }
                
            case 32:
                colorMask = ColorMask(red: 0x00FF0000, green: 0x0000FF00, blue: 0x000000FF, alpha: 0x00000000, redShift: 16, greenShift: 8, blueShift: 0, alphaShift: 0)

                data = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)
                
                fseek(file, dataOffset, SEEK_SET)
                fread(data, 1, imageSize, file)

            default:
                throw BMPError.unsupportedBitCount(bitCount)
            }
        }

        if !verticalFlipped {
            let flippedData = data
            defer { flippedData.deallocate(capacity: imageSize) }

            data = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)

            for row in 0 ..< height {
                for p in 0 ..< bytesPerRow {
                    data[row * bytesPerRow + p] = flippedData[(height - 1 - row) * bytesPerRow + p]
                }
            }
        }

        let buffer = UnsafeRawBufferPointer(start: data, count: imageSize)
        self.init(width: width, height: height, bytesPerRow: bytesPerRow, pixelSize: pixelSize, bitsPerPixel: bitCount, pixelColorMask: colorMask, data: buffer)
    }
}

private func _pow(_ base: Int, _ exponent: Int) -> Int {
    var result = 1
    for _ in 0 ..< exponent {
        result *= base
    }
    return result
}
