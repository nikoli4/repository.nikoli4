import hashlib
import os
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

ADDON_DIRS = [
    "repository.nikoli4",
    "plugin.program.akl",
    "script.akl.screenscraper",
    "script.akl.defaults",
    "skin.arctic.zephyr.mod",
]


def read_addon_xml_from_folder(folder):
    path = os.path.join(ROOT, folder, "addon.xml")
    if not os.path.isfile(path):
        return None

    with open(path, "rb") as f:
        return ET.fromstring(f.read())


def read_addon_xml_from_zip(folder):
    folder_path = os.path.join(ROOT, folder)

    if not os.path.isdir(folder_path):
        return None

    zip_files = [
        f for f in os.listdir(folder_path)
        if f.lower().endswith(".zip")
    ]

    if not zip_files:
        return None

    # For now we expect one current release ZIP per addon folder.
    zip_files.sort()
    zip_path = os.path.join(folder_path, zip_files[-1])

    with zipfile.ZipFile(zip_path, "r") as zf:
        addon_xml_files = [
            name for name in zf.namelist()
            if name.count("/") == 1 and name.endswith("/addon.xml")
        ]

        if len(addon_xml_files) != 1:
            raise RuntimeError(
                f"{zip_path}: expected exactly one top-level addon.xml, "
                f"found {len(addon_xml_files)}"
            )

        xml_data = zf.read(addon_xml_files[0])
        return ET.fromstring(xml_data)


def indent_xml(elem, level=0):
    indent = "\n" + ("    " * level)

    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "    "

        for child in elem:
            indent_xml(child, level + 1)

        if not child.tail or not child.tail.strip():
            child.tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent


def main():
    root = ET.Element("addons")

    for folder in ADDON_DIRS:
        if folder == "repository.nikoli4":
            addon = read_addon_xml_from_folder(folder)
        else:
            addon = read_addon_xml_from_zip(folder)

        if addon is None:
            print(f"ERROR: Could not find addon metadata for {folder}")
            sys.exit(1)

        print(
            f"Adding {addon.attrib.get('id')} "
            f"{addon.attrib.get('version')}"
        )

        root.append(addon)

    indent_xml(root)

    xml_bytes = ET.tostring(
        root,
        encoding="utf-8",
        xml_declaration=True
    )

    addons_xml = os.path.join(ROOT, "addons.xml")
    checksum_file = os.path.join(ROOT, "addons.xml.md5")

    with open(addons_xml, "wb") as f:
        f.write(xml_bytes)
        f.write(b"\n")

    with open(addons_xml, "rb") as f:
        md5 = hashlib.md5(f.read()).hexdigest()

    with open(checksum_file, "w", encoding="ascii", newline="\n") as f:
        f.write(md5)

    print()
    print(f"Wrote: {addons_xml}")
    print(f"Wrote: {checksum_file}")
    print(f"MD5:   {md5}")


if __name__ == "__main__":
    main()