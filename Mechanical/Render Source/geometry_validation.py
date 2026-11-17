"""Check documented package selections against evaluated component mesh evidence.

The ordered CAD and its conservative clearance envelopes are separate inputs.
These checks apply to the documentation models only.
"""

from collections import Counter
import hashlib
import math
from urllib.parse import urlparse


EXPECTED_FAMILIES = {
    'yageo_mfr25': ([6.3, 2.4, 2.4], .35, -2.4, [.55], 'yageo'),
    'stackpole_rnf14': ([6.35, 2.35, 2.35], .35, -2.4, [.56], 'seielect.com'),
    'murata_mhr0317': ([17.6, 2.5, 5.0], .2, -3.3, [.5, .25], 'murata.com'),
    'tdk_fg28': ([4.0, 2.5, 4.1], 1.4, -2.4, [.5], 'tdk.'),
    'tdk_fg18': ([4.0, 2.5, 4.1], 1.4, -2.4, [.5], 'tdk.'),
    'tdk_fg24': ([4.5, 3.0, 4.1], 1.4, -2.4, [.5], 'tdk.'),
    'tdk_fa18': ([4.0, 2.5, 4.1], 1.4, -2.4, [.5], 'tdk.'),
    'kemet_c317': ([3.81, 2.54, 3.88], 1.2, -2.4, [.51], 'kemet.com'),
    'vishay_bat85': ([3.9, 1.7, 1.7], .35, -2.4, [.5], 'vishay.com'),
    'microchip_pdip14': ([19.05, 6.35, 3.302], .381, -3.302, [.4572, .254], 'microchip.com'),
    'harwin2': ([5.08, 2.54, 2.54], 0.0, -3.0, [.64, .64], 'harwin.com'),
    'harwin3': ([7.62, 2.54, 2.54], 0.0, -3.0, [.64, .64], 'harwin.com'),
    'harwin6': ([15.24, 2.54, 2.54], 0.0, -3.0, [.64, .64], 'harwin.com'),
}

EXPECTED_REFERENCES = {
    **dict.fromkeys(['R1', 'R2', 'R4', 'R5', 'R6', 'R9', 'R10'], 'yageo_mfr25'),
    **dict.fromkeys(['R7', 'R8', 'R11', 'R12'], 'stackpole_rnf14'),
    'R3': 'murata_mhr0317',
    **dict.fromkeys(['C1', 'C3', 'C6'], 'tdk_fg28'),
    'C2': 'tdk_fg18',
    **dict.fromkeys(['C5', 'C7'], 'tdk_fg24'),
    'C8': 'tdk_fa18',
    'C4': 'kemet_c317',
    **dict.fromkeys(['D1', 'D2'], 'vishay_bat85'),
    'U1': 'microchip_pdip14',
    'J1': 'harwin2', 'J2': 'harwin3', 'J3': 'harwin6', 'J4': 'harwin2',
}


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _finite(value, label):
    _require(isinstance(value, (int, float)) and not isinstance(value, bool)
             and math.isfinite(value), f'{label}: expected a finite number')
    return value


def _near(actual, expected, label, tolerance=1e-4):
    _finite(actual, label)
    _require(abs(actual - expected) <= tolerance,
             f'{label}: {actual} differs from {expected}')


def _vector(actual, expected, label, tolerance=1e-4):
    _require(isinstance(actual, list) and len(actual) == len(expected),
             f'{label}: invalid vector')
    for index, (value, target) in enumerate(zip(actual, expected)):
        _near(value, target, f'{label}[{index}]', tolerance)


def _finite_tree(value, label):
    """Check limits, preserving null entries for dimensions with no nominal."""
    if isinstance(value, dict):
        _require(bool(value), f'{label}: empty limits record')
        count = 0
        for key, child in value.items():
            count += _finite_tree(child, f'{label}.{key}')
        return count
    elif isinstance(value, list):
        _require(bool(value), f'{label}: empty limits list')
        count = 0
        for index, child in enumerate(value):
            count += _finite_tree(child, f'{label}[{index}]')
        return count
    elif isinstance(value, str):
        _require(bool(value.strip()), f'{label}: empty annotation')
        return 0
    elif value is None:
        return 0
    else:
        _finite(value, label)
        return 1


def _range(value, limits, label):
    _require(isinstance(limits, list) and len(limits) == 3,
             f'{label}: expected minimum, nominal and maximum slots')
    published = [number for number in limits if number is not None]
    _require(published and published == sorted(published), f'{label}: unordered source limits')
    minimum, _, maximum = limits
    _require(minimum is None or value >= minimum - 1e-6, f'{label}: below manufacturer minimum')
    _require(maximum is None or value <= maximum + 1e-6, f'{label}: above manufacturer maximum')


def _check_source_limits(family_id, family, dimensions, bottom, tip, section):
    limits = family['source_limits']
    for key, index in [('length', 0), ('width', 1), ('thickness', 2)]:
        if key in limits:
            _range(dimensions[index], limits[key], f'{family_id}.{key}')
    if 'diameter' in limits:
        for axis in [1, 2]:
            _range(dimensions[axis], limits['diameter'], f'{family_id}.diameter')
    if 'wire_diameter' in limits:
        _range(section[0], limits['wire_diameter'], f'{family_id}.wire_diameter')
    if 'body_max' in limits:
        _require(len(limits['body_max']) == 3 and all(
            selected <= maximum + 1e-6 for selected, maximum in zip(dimensions, limits['body_max'])),
            f'{family_id}: selected body exceeds its maximum envelope')
    for key, value in [('upper_length_max', dimensions[0]), ('length_max', dimensions[0]),
                       ('thickness_max', dimensions[1]), ('diameter_max', dimensions[1]),
                       ('wire_diameter_max', section[0]),
                       ('package_height_max', bottom + dimensions[2]),
                       ('overall_height_max', bottom + dimensions[2])]:
        if key in limits:
            _require(value <= limits[key] + 1e-6, f'{family_id}.{key}: exceeds maximum')
    for key, value in [('length_min', dimensions[0]), ('diameter_min', dimensions[1]),
                       ('wire_diameter_min', section[0]), ('body_standoff_min', bottom)]:
        if key in limits:
            _require(value >= limits[key] - 1e-6, f'{family_id}.{key}: below minimum')
    if 'tip_to_seating_plane' in limits:
        _range(-tip, limits['tip_to_seating_plane'], f'{family_id}.tip_to_seating_plane')
    if family_id.startswith('harwin'):
        _near(-tip, limits['tail_length'], f'{family_id}.tail_length')
        _near(dimensions[2] + limits['mating_length'], limits['above_pcb_height'],
              f'{family_id}.mating_height')


def validate_component_geometry(root, parts, package, proof):
    _require(package.get('schema_version') == proof.get('schema_version') == 1,
             'Unsupported component geometry schema')
    _require(package.get('unit') == 'mm', 'Component geometry units must be mm')
    _require(package.get('ref_family') == EXPECTED_REFERENCES,
             'Documentation package mapping differs from the ordered 27 references')
    _require(set(parts) == set(EXPECTED_REFERENCES), 'Unexpected native reference set')
    families = package.get('families', {})
    _require(set(families) == set(EXPECTED_FAMILIES), 'Unexpected documentation package family')
    sources = package.get('sources', {})
    _require(bool(sources), 'Missing primary package sources')
    for family_id, expected in EXPECTED_FAMILIES.items():
        dimensions, bottom, tip, section, domain = expected
        family = families[family_id]
        _vector(family.get('body_dimensions_mm'), dimensions, f'{family_id}.body_dimensions_mm')
        _near(family.get('body_bottom_z_mm'), bottom, f'{family_id}.body_bottom_z_mm')
        _near(family.get('lead_tip_z_mm'), tip, f'{family_id}.lead_tip_z_mm')
        _vector(family.get('lead_section_mm'), section, f'{family_id}.lead_section_mm')
        _require(isinstance(family.get('shape'), str) and family['shape'], f'{family_id}: no shape')
        _require(bool(family.get('dimension_basis')), f'{family_id}: no nominal/maximum dimension basis')
        assumptions = family.get('illustrative_assumptions')
        _require(isinstance(assumptions, list) and assumptions
                 and all(isinstance(item, str) and item.strip() for item in assumptions),
                 f'{family_id}: mounting or contour assumptions must be explicit')
        limits = family.get('source_limits')
        _require(isinstance(limits, dict) and limits, f'{family_id}: no source limits')
        _require(_finite_tree(limits, f'{family_id}.source_limits') > 0,
                 f'{family_id}: no numeric manufacturer limits')
        _check_source_limits(family_id, family, dimensions, bottom, tip, section)
        source_id = family.get('source')
        _require(source_id in sources, f'{family_id}: unknown source')
        source = sources[source_id]
        parsed = urlparse(source.get('url', ''))
        _require(parsed.scheme == 'https' and domain in parsed.netloc.lower(),
                 f'{family_id}: source must be the documented manufacturer')
        _require(bool(source.get('description')) and 'page' in source,
                 f'{family_id}: missing source description/page reference')

    expected_hashes = {
        'renderer': 'render.py',
        'geometry': 'component_geometry.json',
        'config': 'model_config.json',
    }
    hashes = proof.get('source_sha256', {})
    _require(set(hashes) == set(expected_hashes), 'Incomplete mesh proof source bindings')
    for key, name in expected_hashes.items():
        digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
        _require(hashes[key] == digest, f'Component mesh evidence is stale: {name}')

    components = proof.get('components', [])
    _require(len(components) == 27, 'Expected 27 component mesh proof records')
    _require(Counter(item.get('ref') for item in components) == Counter(parts.keys()),
             'Duplicate or missing component mesh proof')
    lead_count = 0
    section_count = 0
    smallest_radial_margin = math.inf
    for component in components:
        ref = component['ref']
        family_id = EXPECTED_REFERENCES[ref]
        _require(component.get('family') == family_id, f'{ref}: incorrect proof family')
        dimensions, bottom, tip, section, _ = EXPECTED_FAMILIES[family_id]
        world_dimensions = list(dimensions)
        if ref == 'U1':
            world_dimensions = [dimensions[1], dimensions[0], dimensions[2]]
        elif ref in ['J1', 'J2', 'J4']:
            world_dimensions = [dimensions[1], dimensions[0], dimensions[2]]
        body = component.get('body', {})
        _vector(body.get('expected_size_mm'), world_dimensions, f'{ref}.expected_body_size')
        _vector(body.get('actual_size_mm'), world_dimensions, f'{ref}.evaluated_body_size')
        _near(body.get('min_z_mm'), bottom, f'{ref}.body_bottom')
        _near(body.get('max_z_mm'), bottom + dimensions[2], f'{ref}.body_top')
        names = body.get('mesh_names')
        _require(isinstance(names, list) and names and len(names) == len(set(names)),
                 f'{ref}: missing or duplicate evaluated body meshes')
        native_pads = {pad['pin']: pad for pad in parts[ref]['pads']}
        leads = component.get('leads', [])
        _require(Counter(item.get('pin') for item in leads) == Counter(native_pads.keys()),
                 f'{ref}: missing or duplicate lead proof')
        for lead in leads:
            pin = lead['pin']
            native = native_pads[pin]
            expected_center = [native['x'], -native['y']]
            _vector(lead.get('native_pad_mm'), expected_center, f'{ref}.{pin}.native_pad')
            _near(lead.get('expected_tip_z_mm'), tip, f'{ref}.{pin}.expected_tip')
            _near(lead.get('actual_tip_z_mm'), tip, f'{ref}.{pin}.evaluated_tip')
            if family_id.startswith('harwin'):
                _near(lead.get('actual_top_z_mm'), 8.64, f'{ref}.{pin}.evaluated_mating_top')
            sections = lead.get('sections', [])
            _require(len(sections) == 2, f'{ref}.{pin}: two board plane intersections required')
            _require(sorted(item.get('plane_z_mm') for item in sections) == [-1.6, 0],
                     f'{ref}.{pin}: wrong board plane intersections')
            expected_section = [section[0], section[0]] if len(section) == 1 else list(section)
            if ref == 'U1':
                expected_section.reverse()
            for cross_section in sections:
                points = cross_section.get('section_xy_vertices_mm', [])
                label = f'{ref}.{pin} at z={cross_section["plane_z_mm"]}'
                _require(isinstance(points, list) and len(points) >= 4,
                         f'{label}: no evaluated mesh section vertices')
                for point in points:
                    _require(isinstance(point, list) and len(point) == 2, f'{label}: invalid section point')
                    _finite(point[0], label)
                    _finite(point[1], label)
                    radius = math.hypot(point[0] - expected_center[0], point[1] - expected_center[1])
                    margin = native['drill'] / 2 - radius
                    smallest_radial_margin = min(smallest_radial_margin, margin)
                    _require(margin >= -1e-4, f'{label}: actual lead mesh extends outside native bore')
                lows = [min(point[axis] for point in points) for axis in range(2)]
                highs = [max(point[axis] for point in points) for axis in range(2)]
                # Evaluated beveled curves use an inscribed polygon profile. Its
                # axis bounds need not hit the analytic circle's cardinal points;
                # bent tube interpolation also makes the bounds slightly uneven.
                # Keep the bore check above strict and bound both section axes,
                # plus the independently computed circumradius, for round wire.
                measured_section = [hi - lo for lo, hi in zip(lows, highs)]
                _vector([(lo + hi) / 2 for lo, hi in zip(lows, highs)], expected_center,
                        f'{label}.section_center', .001 if len(section) == 1 else 1e-4)
                if len(section) == 1:
                    diameter = section[0]
                    for measured in measured_section:
                        _require(diameter * math.cos(math.pi / 8) <= measured <= diameter + 1e-4,
                                 f'{label}: round wire section axis is outside polygon bounds')
                    measured_radius = max(math.hypot(point[0] - expected_center[0],
                                                    point[1] - expected_center[1]) for point in points)
                    _require(.99 * diameter / 2 <= measured_radius <= diameter / 2 + 1e-4,
                             f'{label}: round wire evaluated radius differs from selected diameter')
                else:
                    _vector(measured_section, expected_section, f'{label}.section_dimensions')
                section_count += 1
            lead_count += 1
    _require(lead_count == 71 and section_count == 142, 'Incomplete lead section proof')
    return {
        'component_package_meshes_verified': len(components),
        'component_leads_verified': lead_count,
        'component_board_plane_sections_verified': section_count,
        'smallest_lead_to_native_bore_radial_margin_mm': smallest_radial_margin,
        'component_geometry_sha256': hashes['geometry'],
        'component_geometry_proof_sha256': hashlib.sha256((root / 'component_geometry_proof.json').read_bytes()).hexdigest(),
    }
