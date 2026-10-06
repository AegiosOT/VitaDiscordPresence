using System.Text;

namespace VitaPresence;

public static class VitaPacket
{
    public const int Port = 0xCAFE;
    public const uint Magic = 0xCAFECAFE;
    public const int MinimumLength = 146;
    public const int WireLength = 148;
    public const int WireLengthWithContentId = 184;
    public const int MaximumReadLength = 4096;
    public const int MaximumIndex = 20;

    private const string ContentIdShape = "XXYYYY-TTTTNNNNN_NN-LLLLLLLLLLLLLLLL";

    public static VitaTitle Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < MinimumLength)
            throw new VitaPacketException($"Packet is {bytes.Length} bytes; need at least {MinimumLength}.");
        var magic = ReadU32(bytes, 0);
        if (magic != Magic)
            throw new VitaPacketException($"Unexpected magic 0x{magic:X8}.");
        var index = (int)ReadU32(bytes, 4);
        if (index < 0 || index > MaximumIndex)
            throw new VitaPacketException($"Index {index} is outside 0...{MaximumIndex}.");
        if (index == 0) return VitaTitle.LiveArea;

        var titleId = Text(bytes.Slice(8, 10));
        var name = Text(bytes.Slice(18, 128));
        string? contentId = null;
        if (bytes.Length >= 183)
            contentId = ContentId(bytes.Slice(146, 37));
        return new VitaTitle(index, titleId, name, contentId);
    }

    public static byte[] Encode(VitaTitle title)
    {
        var packet = new byte[title.ContentId is null ? WireLength : WireLengthWithContentId];
        WriteU32(packet, 0, Magic);
        WriteU32(packet, 4, (uint)title.Index);
        WriteText(packet, 8, 10, title.TitleId);
        WriteText(packet, 18, 128, title.Name);
        if (title.ContentId is not null)
            WriteText(packet, 146, 37, title.ContentId);
        return packet;
    }

    private static uint ReadU32(ReadOnlySpan<byte> bytes, int offset) =>
        bytes[offset] | (uint)bytes[offset + 1] << 8 | (uint)bytes[offset + 2] << 16 | (uint)bytes[offset + 3] << 24;

    private static void WriteU32(byte[] packet, int offset, uint value)
    {
        packet[offset] = (byte)value;
        packet[offset + 1] = (byte)(value >> 8);
        packet[offset + 2] = (byte)(value >> 16);
        packet[offset + 3] = (byte)(value >> 24);
    }

    private static string Text(ReadOnlySpan<byte> field)
    {
        var end = field.IndexOf((byte)0);
        if (end < 0) end = field.Length;
        var slice = field[..end];
        var drop = IncompleteSequenceLength(slice);
        if (drop > 0) slice = slice[..^drop];
        var text = Encoding.UTF8.GetString(slice);
        var builder = new StringBuilder(text.Length);
        foreach (var scalar in text.EnumerateRunes())
        {
            if (scalar.Value >= 0x20 && scalar.Value != 0x7F)
                builder.Append(scalar.ToString());
        }
        return builder.ToString().Trim();
    }

    private static string? ContentId(ReadOnlySpan<byte> field)
    {
        var end = field.IndexOf((byte)0);
        if (end < 0) end = field.Length;
        var id = field[..end];
        if (id.Length != ContentIdShape.Length) return null;
        for (var i = 0; i < id.Length; i++)
        {
            var shape = (byte)ContentIdShape[i];
            var value = id[i];
            if (IsLetter(shape))
            {
                if (!IsLetter(value) && !IsDigit(value)) return null;
            }
            else if (value != shape)
            {
                return null;
            }
        }
        return Encoding.ASCII.GetString(id).ToUpperInvariant();
    }

    private static bool IsLetter(byte value) =>
        value is >= (byte)'A' and <= (byte)'Z' or >= (byte)'a' and <= (byte)'z';

    private static bool IsDigit(byte value) => value is >= (byte)'0' and <= (byte)'9';

    /// Bytes at the end that start a UTF-8 sequence and stop before it finishes.
    private static int IncompleteSequenceLength(ReadOnlySpan<byte> bytes)
    {
        var start = bytes.Length;
        while (start > 0 && bytes.Length - start < 3 && (bytes[start - 1] & 0xC0) == 0x80)
            start--;
        if (start == 0) return 0;
        var lead = bytes[start - 1];
        int length;
        byte secondMin, secondMax;
        switch (lead)
        {
            case >= 0xC2 and <= 0xDF: (length, secondMin, secondMax) = (2, 0x80, 0xBF); break;
            case 0xE0: (length, secondMin, secondMax) = (3, 0xA0, 0xBF); break;
            case >= 0xE1 and <= 0xEC:
            case >= 0xEE and <= 0xEF: (length, secondMin, secondMax) = (3, 0x80, 0xBF); break;
            case 0xED: (length, secondMin, secondMax) = (3, 0x80, 0x9F); break;
            case 0xF0: (length, secondMin, secondMax) = (4, 0x90, 0xBF); break;
            case >= 0xF1 and <= 0xF3: (length, secondMin, secondMax) = (4, 0x80, 0xBF); break;
            case 0xF4: (length, secondMin, secondMax) = (4, 0x80, 0x8F); break;
            default: return 0;
        }
        var present = bytes.Length - (start - 1);
        if (present >= length) return 0;
        if (present != 1 && (bytes[start] < secondMin || bytes[start] > secondMax)) return 0;
        return present;
    }

    private static void WriteText(byte[] packet, int offset, int fieldLength, string text)
    {
        var utf8 = Encoding.UTF8.GetBytes(text);
        var length = Math.Min(utf8.Length, fieldLength - 1);
        while (length < utf8.Length && (utf8[length] & 0xC0) == 0x80)
            length--;
        utf8.AsSpan(0, length).CopyTo(packet.AsSpan(offset));
    }
}

public sealed class VitaPacketException(string message) : Exception(message);
