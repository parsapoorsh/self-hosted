#!/usr/bin/env python3
"""Disable Nexus Community Edition content usage limits.

Nexus CE blocks hosted uploads once an instance reaches 40,000 components or
100,000 requests per day, and reports those caps on the usage page and H2
health check.  This script builds a tiny override JAR from the shipped classes
and puts it on Spring Boot's loader path, so the patched classes win over the
copies inside the main JAR.
"""
import glob
import io
import os
import struct
import sys
import zipfile

PATCH_DIR = "/nexus-data/patch"
PATCH_JAR = os.path.join(PATCH_DIR, "nexus-content-usage-patch.jar")
FAT_JAR_GLOB = "/opt/sonatype/nexus/bin/sonatype-nexus-repository-*.jar"

CONTENT_USAGE_CLASS = "com/sonatype/nexus/community/analytics/ContentUsage.class"
CONTENT_USAGE_STATE_CLASS = (
    "com/sonatype/nexus/community/analytics/internal/ContentUsageStateContributor.class"
)
CONTENT_USAGE_LIMITS_CLASS = (
    "com/sonatype/nexus/analytics/limits/ContentUsageLimits.class"
)
SOFT_LIMITS_HEALTH_CLASS = (
    "com/sonatype/nexus/analytics/internal/metrics/SoftLimitsHealthCheck.class"
)

NESTED_JARS = {
    "nexus-community-edition-plugin-": (
        CONTENT_USAGE_CLASS,
        CONTENT_USAGE_STATE_CLASS,
    ),
    "nexus-analytics-common-": (
        CONTENT_USAGE_LIMITS_CLASS,
        SOFT_LIMITS_HEALTH_CLASS,
    ),
}


def read_u2(data, offset):
    return struct.unpack_from(">H", data, offset)[0], offset + 2


def read_u4(data, offset):
    return struct.unpack_from(">I", data, offset)[0], offset + 4


def read_constant_pool(data, offset):
    """Return (end offset, utf8 map, constant pool entries)."""
    count, offset = read_u2(data, offset)
    utf8 = {}
    entries = {}
    index = 1
    while index < count:
        tag = data[offset]
        offset += 1
        if tag == 1:
            length, offset = read_u2(data, offset)
            utf8[index] = bytes(data[offset:offset + length]).decode("utf-8", "replace")
            offset += length
        elif tag in (7, 8, 16, 19, 20):
            value, offset = read_u2(data, offset)
            entries[index] = (tag, value)
        elif tag == 15:
            offset += 3
        elif tag == 9:
            class_index, offset = read_u2(data, offset)
            name_type_index, offset = read_u2(data, offset)
            entries[index] = (tag, class_index, name_type_index)
        elif tag == 12:
            name_index, offset = read_u2(data, offset)
            descriptor_index, offset = read_u2(data, offset)
            entries[index] = (tag, name_index, descriptor_index)
        elif tag in (3, 4, 10, 11, 17, 18):
            offset += 4
        elif tag in (5, 6):
            offset += 8
            index += 1
        else:
            raise ValueError("unknown constant pool tag %d" % tag)
        index += 1
    return offset, utf8, entries


def read_members(data, offset, utf8):
    """Return (end offset, member list) for fields or methods."""
    count, offset = read_u2(data, offset)
    members = []
    for _ in range(count):
        access, offset = read_u2(data, offset)
        name_index, offset = read_u2(data, offset)
        descriptor_index, offset = read_u2(data, offset)
        attr_count, offset = read_u2(data, offset)
        attrs = []
        for _ in range(attr_count):
            name, offset = read_u2(data, offset)
            length, offset = read_u4(data, offset)
            attrs.append({
                "name_index": name,
                "name": utf8.get(name),
                "start": offset - 6,
                "length": length,
                "info_start": offset,
            })
            offset += length
        members.append({
            "name": utf8.get(name_index),
            "descriptor": utf8.get(descriptor_index),
            "attrs": attrs,
        })
    return offset, members


def find_string_constant(class_bytes, value):
    """Return the constant pool index of a String constant."""
    _, utf8, entries = read_constant_pool(memoryview(class_bytes), 8)
    for index, entry in entries.items():
        if entry[0] == 8 and utf8.get(entry[1]) == value:
            return index
    raise ValueError("String constant %r not found" % value)


def find_field_constant(class_bytes, class_name, field_name, descriptor):
    """Return the constant pool index of a Fieldref constant."""
    _, utf8, entries = read_constant_pool(memoryview(class_bytes), 8)
    for index, entry in entries.items():
        if entry[0] != 9:
            continue
        class_entry = entries.get(entry[1])
        name_type = entries.get(entry[2])
        if not class_entry or class_entry[0] != 7:
            continue
        if not name_type or name_type[0] != 12:
            continue
        if (
            utf8.get(class_entry[1]) == class_name
            and utf8.get(name_type[1]) == field_name
            and utf8.get(name_type[2]) == descriptor
        ):
            return index
    raise ValueError("field %s.%s not found" % (class_name, field_name))


def string_return_code(class_bytes, value):
    index = find_string_constant(class_bytes, value)
    load = b"\x12" + bytes([index]) if index <= 255 else b"\x13" + struct.pack(">H", index)
    return load + b"\xb0"  # areturn


def enum_return_code(class_bytes, class_name, field_name, descriptor):
    index = find_field_constant(class_bytes, class_name, field_name, descriptor)
    return b"\xb2" + struct.pack(">H", index) + b"\xb0"  # getstatic, areturn


def patch_method(
    class_bytes,
    method_name,
    descriptor,
    code,
    max_stack,
    max_locals,
):
    """Replace one method's Code attribute, leaving the rest of the class alone."""
    data = bytearray(class_bytes)
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("not a class file")
    offset, utf8, _ = read_constant_pool(data, 8)
    offset += 6  # access_flags, this_class, super_class
    interfaces, offset = read_u2(data, offset)
    offset += 2 * interfaces
    offset, _ = read_members(data, offset, utf8)  # fields
    offset, methods = read_members(data, offset, utf8)

    target = None
    for method in methods:
        if method["name"] == method_name and method["descriptor"] == descriptor:
            target = method
            break
    if target is None:
        raise ValueError("method %s%s not found" % (method_name, descriptor))

    for attr in target["attrs"]:
        if attr["name"] == "Code":
            info = struct.pack(
                ">HHI",
                max_stack,
                max_locals,
                len(code),
            ) + code + struct.pack(">HH", 0, 0)
            new_attr = struct.pack(">HI", attr["name_index"], len(info)) + info
            end = attr["info_start"] + attr["length"]
            return bytes(data[:attr["start"]] + new_attr + data[end:])
    raise ValueError("Code attribute not found for %s%s" % (method_name, descriptor))


def read_shipped_classes():
    candidates = glob.glob(FAT_JAR_GLOB)
    if not candidates:
        raise FileNotFoundError("Nexus main JAR not found")
    classes = {}
    with zipfile.ZipFile(candidates[0]) as fat_jar:
        for prefix, class_names in NESTED_JARS.items():
            nested = [
                name for name in fat_jar.namelist()
                if name.startswith("BOOT-INF/lib/" + prefix)
                and name.endswith(".jar")
            ]
            if not nested:
                continue
            with zipfile.ZipFile(io.BytesIO(fat_jar.read(nested[0]))) as jar:
                for name in class_names:
                    if name in jar.namelist():
                        classes[name] = jar.read(name)
    return classes


def write_patch(classes):
    os.makedirs(PATCH_DIR, exist_ok=True)
    temp_path = PATCH_JAR + ".tmp"
    with zipfile.ZipFile(temp_path, "w", zipfile.ZIP_DEFLATED) as patch:
        for name, class_bytes in (classes or {}).items():
            patch.writestr(name, class_bytes)
    # An empty JAR keeps loader.path valid when a future Nexus changes a class.
    os.replace(temp_path, PATCH_JAR)


def build_patches(shipped):
    content_usage = shipped.get(CONTENT_USAGE_CLASS)
    if content_usage is None:
        raise FileNotFoundError("ContentUsage class not found")
    patched = {
        CONTENT_USAGE_CLASS: patch_method(
            content_usage,
            "shouldBlock",
            "()Z",
            b"\x03\xac",  # iconst_0, ireturn
            1,
            1,
        )
    }

    optional = (
        (
            CONTENT_USAGE_STATE_CLASS,
            "findThrottlingStatus",
            "()Ljava/lang/String;",
            lambda data: string_return_code(data, "Under limits"),
        ),
        (
            CONTENT_USAGE_LIMITS_CLASS,
            "getContentUtilization",
            "(Lcom/sonatype/nexus/analytics/limits/LimitType;J)"
            "Lcom/sonatype/nexus/analytics/limits/ContentUtilization;",
            lambda data: enum_return_code(
                data,
                "com/sonatype/nexus/analytics/limits/ContentUtilization",
                "FREE_TIER",
                "Lcom/sonatype/nexus/analytics/limits/ContentUtilization;",
            ),
        ),
        (
            SOFT_LIMITS_HEALTH_CLASS,
            "shouldApply",
            "()Z",
            lambda data: b"\x03\xac",  # iconst_0, ireturn
        ),
    )
    for class_name, method_name, descriptor, code_builder in optional:
        class_bytes = shipped.get(class_name)
        if class_bytes is None:
            print("usage-limit patch: %s not found" % class_name, file=sys.stderr)
            continue
        try:
            patched[class_name] = patch_method(
                class_bytes,
                method_name,
                descriptor,
                code_builder(class_bytes),
                1,
                max_locals=1 if descriptor == "()Z" or descriptor.startswith("()L") else 4,
            )
        except Exception as exc:
            print(
                "usage-limit patch: %s not patched (%s)" % (class_name, exc),
                file=sys.stderr,
            )
    return patched


def main():
    try:
        patched = build_patches(read_shipped_classes())
    except Exception as exc:
        write_patch(None)
        print("usage-limit patch: skipped (%s)" % exc, file=sys.stderr)
        return 1
    write_patch(patched)
    print("usage-limit patch: content usage limits disabled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
