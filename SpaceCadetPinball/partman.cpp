#include "pch.h"
#include "partman.h"

#include "gdrv.h"
#include "GroupData.h"
#include "zdrv.h"

static inline int16_t ReadLeI16(int16_t value)
{
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
	return static_cast<int16_t>(SDL_Swap16(static_cast<uint16_t>(value)));
#else
	return value;
#endif
}

static inline uint16_t ReadLeU16(uint16_t value)
{
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
	return SDL_Swap16(value);
#else
	return value;
#endif
}

static inline int32_t ReadLeI32(int32_t value)
{
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
	return static_cast<int32_t>(SDL_Swap32(static_cast<uint32_t>(value)));
#else
	return value;
#endif
}

static inline uint32_t ReadLeU32(uint32_t value)
{
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
	return SDL_Swap32(value);
#else
	return value;
#endif
}

static inline float ReadLeFloat(float value)
{
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
	uint32_t bits = 0;
	std::memcpy(&bits, &value, sizeof(bits));
	bits = SDL_Swap32(bits);
	float result = 0.0f;
	std::memcpy(&result, &bits, sizeof(result));
	return result;
#else
	return value;
#endif
}

short partman::_field_size[] =
{
	2, -1, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0
};

DatFile* partman::load_records(LPCSTR lpFileName, bool fullTiltMode)
{
	datFileHeader header{};
	dat8BitBmpHeader bmpHeader{};
	dat16BitBmpHeader zMapHeader{};

	auto fileHandle = fopenu(lpFileName, "rb");
	if (fileHandle == nullptr)
		return nullptr;

	fread(&header, 1, sizeof header, fileHandle);
	if (strcmp("PARTOUT(4.0)RESOURCE", header.FileSignature) != 0)
	{
		fclose(fileHandle);
		return nullptr;
	}
	header.FileSize = ReadLeI32(header.FileSize);
	header.NumberOfGroups = ReadLeU16(header.NumberOfGroups);
	header.SizeOfBody = ReadLeI32(header.SizeOfBody);
	header.Unknown = ReadLeU16(header.Unknown);

	auto datFile = new DatFile();
	if (!datFile)
	{
		fclose(fileHandle);
		return nullptr;
	}

	datFile->AppName = header.AppName;
	datFile->Description = header.Description;

	if (header.Unknown)
	{
		auto unknownBuf = new char[header.Unknown];
		if (!unknownBuf)
		{
			fclose(fileHandle);
			delete datFile;
			return nullptr;
		}
		fread(unknownBuf, 1, header.Unknown, fileHandle);
		delete[] unknownBuf;
	}

	datFile->Groups.reserve(header.NumberOfGroups);
	bool abort = false;
	for (auto groupIndex = 0; !abort && groupIndex < header.NumberOfGroups; ++groupIndex)
	{
		auto entryCount = LRead<uint8_t>(fileHandle);
		auto groupData = new GroupData(groupIndex);
		groupData->ReserveEntries(entryCount);

		for (auto entryIndex = 0; entryIndex < entryCount; ++entryIndex)
		{
			auto entryData = new EntryData();
			auto entryType = static_cast<FieldTypes>(LRead<uint8_t>(fileHandle));
			entryData->EntryType = entryType;

			int fixedSize = _field_size[static_cast<int>(entryType)];
			size_t fieldSize = fixedSize >= 0 ? fixedSize : ReadLeU32(LRead<uint32_t>(fileHandle));
			entryData->FieldSize = static_cast<int>(fieldSize);

			if (entryType == FieldTypes::Bitmap8bit)
			{
				fread(&bmpHeader, 1, sizeof(dat8BitBmpHeader), fileHandle);
				bmpHeader.Width = ReadLeI16(bmpHeader.Width);
				bmpHeader.Height = ReadLeI16(bmpHeader.Height);
				bmpHeader.XPosition = ReadLeI16(bmpHeader.XPosition);
				bmpHeader.YPosition = ReadLeI16(bmpHeader.YPosition);
				bmpHeader.Size = ReadLeI32(bmpHeader.Size);
				assertm(bmpHeader.Size + sizeof(dat8BitBmpHeader) == fieldSize, "partman: Wrong bitmap field size");
				assertm(bmpHeader.Resolution <= 2, "partman: bitmap resolution out of bounds");

				auto bmp = new gdrv_bitmap8(bmpHeader);
				entryData->Buffer = reinterpret_cast<char*>(bmp);
				fread(bmp->IndexedBmpPtr, 1, bmpHeader.Size, fileHandle);
			}
			else if (entryType == FieldTypes::Bitmap16bit)
			{
				/*Full tilt has extra byte(@0:resolution) in zMap*/
				auto zMapResolution = 0u;
				if (fullTiltMode)
				{
					zMapResolution = LRead<uint8_t>(fileHandle);
					fieldSize--;

					// -1 means universal resolution, maybe. FT demo .006 is the only known user.	
					if (zMapResolution == 0xff)
						zMapResolution = 0;

					assertm(zMapResolution <= 2, "partman: zMap resolution out of bounds");
				}

				fread(&zMapHeader, 1, sizeof(dat16BitBmpHeader), fileHandle);
				zMapHeader.Width = ReadLeI16(zMapHeader.Width);
				zMapHeader.Height = ReadLeI16(zMapHeader.Height);
				zMapHeader.Stride = ReadLeI16(zMapHeader.Stride);
				zMapHeader.Unknown0 = ReadLeI32(zMapHeader.Unknown0);
				zMapHeader.Unknown1_0 = ReadLeI16(zMapHeader.Unknown1_0);
				zMapHeader.Unknown1_1 = ReadLeI16(zMapHeader.Unknown1_1);
				auto length = fieldSize - sizeof(dat16BitBmpHeader);

				zmap_header_type* zMap;
				if (zMapHeader.Stride * zMapHeader.Height * 2u == length)
				{
					zMap = new zmap_header_type(zMapHeader.Width, zMapHeader.Height, zMapHeader.Stride);
					zMap->Resolution = zMapResolution;
					fread(zMap->ZPtr1, 1, length, fileHandle);
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
					const auto pixelCount = static_cast<size_t>(zMap->Stride) * zMap->Height;
					for (size_t pixelIndex = 0; pixelIndex < pixelCount; ++pixelIndex)
						zMap->ZPtr1[pixelIndex] = ReadLeU16(zMap->ZPtr1[pixelIndex]);
#endif
				}
				else
				{
					// 3DPB .dat has zeroed zMap headers, in groups 497 and 498, skip them.
					fseek(fileHandle, static_cast<int>(length), SEEK_CUR);
					zMap = new zmap_header_type(0, 0, 0);
				}
				entryData->Buffer = reinterpret_cast<char*>(zMap);
			}
			else
			{
				auto entryBuffer = new char[fieldSize];
				entryData->Buffer = entryBuffer;
				if (!entryBuffer)
				{
					abort = true;
					break;
				}
				fread(entryBuffer, 1, fieldSize, fileHandle);
#if SDL_BYTEORDER == SDL_BIG_ENDIAN
				if (entryType == FieldTypes::ShortValue || entryType == FieldTypes::ShortArray)
				{
					auto shortData = reinterpret_cast<uint16_t*>(entryBuffer);
					const auto count = fieldSize / sizeof(uint16_t);
					for (size_t i = 0; i < count; ++i)
						shortData[i] = ReadLeU16(shortData[i]);
				}
				else if (entryType == FieldTypes::FloatArray)
				{
					auto floatData = reinterpret_cast<float*>(entryBuffer);
					const auto count = fieldSize / sizeof(float);
					for (size_t i = 0; i < count; ++i)
						floatData[i] = ReadLeFloat(floatData[i]);
				}
#endif
			}

			groupData->AddEntry(entryData);
		}

		datFile->Groups.push_back(groupData);
	}

	fclose(fileHandle);
	if (datFile->Groups.size() == header.NumberOfGroups)
	{
		datFile->Finalize();
		return datFile;
	}
	delete datFile;
	return nullptr;
}
