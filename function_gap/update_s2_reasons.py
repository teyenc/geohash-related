import csv

input_file = '/net/dev-server-te-yenchou/share/code/geohash-related/function_gap/data/PostGIS-geohash-categorization.csv'
output_file = '/net/dev-server-te-yenchou/share/code/geohash-related/function_gap/data/PostGIS-geohash-categorization_updated.csv'

group1_bbox = ['&&', '@', '~', '~=', '<<', '>>', '&<', '&>', '&<|', '<<|', '|&>', '|>>', '&=', "'="]
group2_topo = ['ST_Intersects', 'ST_Contains', 'ST_Crosses', 'ST_Disjoint', 'ST_Equals', 'ST_Overlaps', 'ST_Touches', 'ST_Within', 'ST_ContainsProperly', 'ST_CoveredBy', 'ST_Covers']
group3_complex = ['ST_LineCrossingDirection', 'ST_OrderingEquals', 'ST_Relate', 'ST_RelateMatch']
group4_dist = ['ST_DWithin', 'ST_PointInsideCircle', 'ST_DFullyWithin']
group5_extent = ['ST_EstimatedExtent']

def get_new_reason(func_name, current_reason):
    if func_name in group5_extent:
        return "No - Taking the MIN/MAX of an S2 Hilbert curve yields endpoints on a 1D line. Converting that span back to a 2D bounding box results in a massive spatial overestimation. Fast extent estimation requires dedicated 2D statistics, not a 1D curve."
    
    if func_name in group1_bbox:
        return "Yes (Mathematically) - S2's RegionCoverer and Hilbert curve map bounding boxes into a bounded number of contiguous 1D range scans. This greatly reduces the index fragmentation seen in Geohash (Z-curve). However, realizing this in YB requires an index structure (like ybgin or a custom opclass) that can push these multiple range scans down to DocDB; otherwise, it still falls back to a Seq Scan."
    
    if func_name in group3_complex:
        return "Yes, BUT only if explicitly structured. The Postgres planner won't automatically use an S2 index for these functions. The user must manually inject a bounding-box/S2 overlap check (e.g., WHERE s2_overlap(...) AND ST_Relate(...)) to utilize the index, otherwise it forces a full Sequential Scan."
    
    if func_name in group2_topo:
        if func_name == 'ST_Disjoint':
            # Disjoint stays "No" because it requires a full scan
            return current_reason
        return "Yes - S2's adaptive covering generates a tight, bounded list of cells for complex geometries. This makes it feasible to build an inverted index (e.g., using ybgin) to do index lookups. Geohash cannot do this efficiently because its coverings are too fragmented. (Note: GEOS C-library is still required for exact post-filtering)."
    
    if func_name in group4_dist:
        return "Yes - For Point data, S2 covers the search radius (S2Cap) with a small number of contiguous Hilbert intervals, allowing efficient DocDB BETWEEN range scans. (Note: Indexing distance to Lines/Polygons still hits the multi-cell indexing structural gap)."
        
    return current_reason

with open(input_file, 'r', encoding='utf-8') as f_in, open(output_file, 'w', encoding='utf-8', newline='') as f_out:
    reader = csv.reader(f_in)
    writer = csv.writer(f_out)
    
    header = next(reader)
    writer.writerow(header)
    
    # Find the index of "Does S2 Improve This? & Reason"
    s2_col_idx = -1
    for i, col in enumerate(header):
        if "Does S2 Improve This?" in col:
            s2_col_idx = i
            break
            
    for row in reader:
        if len(row) > s2_col_idx:
            func_col = row[1]
            func_name = func_col.split(' — ')[0].strip() if ' — ' in func_col else func_col.strip()
            
            # Keep original #ERROR fix
            if func_col.startswith('#ERROR!') or func_col.startswith("'="):
                func_name = "'="
                row[1] = "'= — Returns TRUE if A's bounding box is the same as B's."
            
            # Apply the new reasoning if it exists
            current_reason = row[s2_col_idx]
            new_reason = get_new_reason(func_name, current_reason)
            row[s2_col_idx] = new_reason
            
        writer.writerow(row)

print("Updated CSV saved.")