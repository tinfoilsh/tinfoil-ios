//
//  MapWidget.swift
//  TinfoilChat
//
//  Native MapKit-backed map widget. Mirrors the webapp's `render_map`
//  but uses iOS's first-party MapKit so no consent gate or external
//  loader is required. Renders one or more pinned locations with a
//  button to open the place (or directions, when there are multiple
//  stops) in the Maps app.

import CoreLocation
import MapKit
import OpenAI
import SwiftUI
import UIKit

struct MapWidget: GenUIWidget {
    struct Location: Decodable, Equatable {
        let name: String
        let address: String?
        let latitude: Double?
        let longitude: Double?
        let description: String?
    }

    struct Args: Decodable {
        let title: String?
        let mode: String?
        let query: String?
        let locations: [Location]
        let travelMode: String?
        let mapType: String?
    }

    let name = "render_map"
    let description = """
        Display an interactive Apple Map with one or more pinned locations and \
        a button to open the place (or directions, when multiple stops are \
        provided) in the Maps app. Use when the user asks about places, \
        addresses, routes, or wants to see somewhere on a map. Provide \
        latitude/longitude when known; otherwise an address string is \
        geocoded automatically.
        """
    let promptHint = "an interactive Apple Map with one or more locations and a button to open Apple Maps"

    var schema: JSONSchema {
        let location = GenUISchema.object(
            properties: [
                "name": GenUISchema.string(description: "Display name shown on the pin"),
                "address": GenUISchema.string(description: "Full address or place query (e.g. \"1 Apple Park Way, Cupertino, CA\" or \"Eiffel Tower, Paris\"). Used for geocoding when coordinates are not provided."),
                "latitude": GenUISchema.number(description: "Latitude in degrees. Always provide when known to avoid geocoding ambiguity."),
                "longitude": GenUISchema.number(description: "Longitude in degrees. Always provide when known to avoid geocoding ambiguity."),
                "description": GenUISchema.string(description: "One-line subtitle"),
            ],
            required: ["name"]
        )
        return GenUISchema.object(
            properties: [
                "title": GenUISchema.string(),
                "mode": GenUISchema.string(
                    description: "`place` (default) for a single location, `search` for a POI query, `directions` for a routed list",
                    enumValues: ["place", "search", "directions"]
                ),
                "query": GenUISchema.string(description: "Used when `mode === \"search\"`, e.g. \"coffee\""),
                "locations": GenUISchema.array(items: location, minItems: 1),
                "travelMode": GenUISchema.string(enumValues: ["driving", "walking", "transit", "cycling"]),
                "mapType": GenUISchema.string(
                    description: "Visual style of the map tiles",
                    enumValues: ["standard", "hybrid", "satellite", "muted"]
                ),
            ],
            required: ["locations"]
        )
    }

    @MainActor
    func renderInline(args: Args, context: GenUIRenderContext) -> AnyView? {
        AnyView(MapWidgetView(args: args, isDarkMode: context.isDarkMode))
    }
}

// MARK: - Pin annotation

private struct MapPinItem: Identifiable {
    let id: Int
    let coordinate: CLLocationCoordinate2D
    let name: String
    let subtitle: String?
}

// MARK: - Open-in-Maps URL builders

private func encodeAddressOrCoord(_ loc: MapWidget.Location) -> String? {
    if let lat = loc.latitude, let lon = loc.longitude, isValidCoordinate(latitude: lat, longitude: lon) {
        return "\(lat),\(lon)"
    }
    if let address = loc.address, !address.isEmpty { return address }
    if !loc.name.isEmpty { return loc.name }
    return nil
}

private let appleMapsQueryAllowedCharacters: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return allowed
}()

private func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: appleMapsQueryAllowedCharacters) ?? value
}

private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
    latitude.isFinite
        && longitude.isFinite
        && (-90.0...90.0).contains(latitude)
        && (-180.0...180.0).contains(longitude)
}

private func placeURL(for loc: MapWidget.Location) -> URL? {
    var params: [String] = []
    if let lat = loc.latitude, let lon = loc.longitude, isValidCoordinate(latitude: lat, longitude: lon) {
        params.append("ll=\(lat),\(lon)")
        if !loc.name.isEmpty { params.append("q=\(encode(loc.name))") }
    } else if let address = loc.address, !address.isEmpty {
        params.append("address=\(encode(address))")
    } else if !loc.name.isEmpty {
        params.append("q=\(encode(loc.name))")
    }
    let query = params.isEmpty ? "" : "?\(params.joined(separator: "&"))"
    return URL(string: "https://maps.apple.com/\(query)")
}

private func searchURL(query: String, center: MapWidget.Location?) -> URL? {
    var params: [String] = ["q=\(encode(query))"]
    if let center, let lat = center.latitude, let lon = center.longitude, isValidCoordinate(latitude: lat, longitude: lon) {
        params.append("sll=\(lat),\(lon)")
    }
    return URL(string: "https://maps.apple.com/?\(params.joined(separator: "&"))")
}

private func directionsURL(locations: [MapWidget.Location], travelMode: String?) -> URL? {
    let points = locations.compactMap(encodeAddressOrCoord)
    guard !points.isEmpty else { return URL(string: "https://maps.apple.com/?dirflg=d") }
    var params: [String] = []
    if points.count == 1 {
        params.append("daddr=\(encode(points[0]))")
    } else {
        params.append("saddr=\(encode(points.first!))")
        let waypoints = points.dropFirst().joined(separator: " to ")
        params.append("daddr=\(encode(waypoints))")
    }
    if let mode = travelMode {
        let flag: String?
        switch mode {
        case "driving": flag = "d"
        case "walking": flag = "w"
        case "transit": flag = "r"
        case "cycling": flag = "d" // Apple Maps doesn't expose cycling via URL — fall back to driving
        default: flag = nil
        }
        if let flag { params.append("dirflg=\(flag)") }
    }
    return URL(string: "https://maps.apple.com/?\(params.joined(separator: "&"))")
}

private func primaryAppleMapsURL(args: MapWidget.Args) -> URL? {
    if args.mode == "directions" || args.locations.count > 1 {
        return directionsURL(locations: args.locations, travelMode: args.travelMode)
    }
    if args.mode == "search", let query = args.query, !query.isEmpty {
        return searchURL(query: query, center: args.locations.first)
    }
    if let first = args.locations.first {
        return placeURL(for: first)
    }
    return URL(string: "https://maps.apple.com/")
}

private func modeBadge(_ args: MapWidget.Args) -> String? {
    if args.mode == "directions" || (args.mode == nil && args.locations.count > 1) {
        return "Directions"
    }
    if args.mode == "search" { return "Search results" }
    return nil
}

// MARK: - Native Map view

private struct MapWidgetView: View {
    let args: MapWidget.Args
    let isDarkMode: Bool

    @State private var pins: [MapPinItem] = []
    @State private var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
    )
    @State private var copyConfirmation: Bool = false

    private var primary: MapWidget.Location? { args.locations.first }
    private var isDirections: Bool {
        args.mode == "directions" || args.locations.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            mapView
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                        .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                )

            if args.locations.count > 1 {
                locationList
            }

            actionsRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .fill(GenUIStyle.cardBackground(isDarkMode))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GenUIStyle.cornerRadius)
                .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
        )
        .task(id: locationsKey) {
            await resolvePins()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mapAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private var mapAccessibilityLabel: String {
        var parts: [String] = []
        if let title = args.title, !title.isEmpty {
            parts.append(title)
        }
        parts.append("Map with \(args.locations.count) location\(args.locations.count == 1 ? "" : "s")")
        if let first = args.locations.first {
            parts.append(first.name)
        }
        return parts.joined(separator: ", ")
    }

    private var locationsKey: String {
        var parts: [String] = []
        for loc in args.locations {
            let lat = loc.latitude.map { String($0) } ?? ""
            let lon = loc.longitude.map { String($0) } ?? ""
            let address = loc.address ?? ""
            let description = loc.description ?? ""
            let fields: [String] = [loc.name, address, lat, lon, description]
            parts.append(fields.joined(separator: "|"))
        }
        return parts.joined(separator: "~")
    }

    @ViewBuilder
    private var header: some View {
        if args.title != nil || modeBadge(args) != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let badge = modeBadge(args) {
                    Text(badgeText(badge: badge))
                        .font(.caption2.weight(.semibold))
                        .tracking(1.0)
                        .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                if let title = args.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                }
            }
        }
    }

    private func badgeText(badge: String) -> String {
        if args.mode == "search", let query = args.query, !query.isEmpty {
            return "\(badge.uppercased()) · \(query)"
        }
        return badge.uppercased()
    }

    private var mapType: MKMapType {
        switch args.mapType {
        case "hybrid": return .hybrid
        case "satellite": return .satellite
        case "muted": return .mutedStandard
        default: return .standard
        }
    }

    private var mapView: some View {
        MapViewRepresentable(region: region, pins: pins, mapType: mapType)
    }

    private var locationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(args.locations.enumerated()), id: \.offset) { index, loc in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                        .frame(width: 20, height: 20)
                        .background(
                            Circle().fill(GenUIStyle.subtleBackground(isDarkMode))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(GenUIStyle.primaryText(isDarkMode))
                            .lineLimit(1)
                        if let secondary = loc.description ?? loc.address, !secondary.isEmpty {
                            Text(secondary)
                                .font(.caption)
                                .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        if let url = placeURL(for: loc) { UIApplication.shared.open(url) }
                    } label: {
                        Text("Open")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(GenUIStyle.mutedText(isDarkMode))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: GenUIStyle.smallCornerRadius)
                        .fill(GenUIStyle.subtleBackground(isDarkMode))
                )
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Spacer()
            if args.locations.count == 1, let primary, primary.address != nil {
                Button(action: copyAddress) {
                    HStack(spacing: 6) {
                        Image(systemName: copyConfirmation ? "checkmark" : "doc.on.doc")
                        Text(copyConfirmation ? "Copied" : "Copy address")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(GenUIStyle.borderColor(isDarkMode), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(GenUIStyle.primaryText(isDarkMode))
            }
            Button(action: openInMaps) {
                HStack(spacing: 6) {
                    Image(systemName: isDirections ? "arrow.triangle.turn.up.right.circle" : "mappin.and.ellipse")
                    Text(isDirections ? "Open directions" : "Open in Apple Maps")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundColor(isDarkMode ? .black : .white)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(GenUIStyle.primaryText(isDarkMode))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func openInMaps() {
        if let url = primaryAppleMapsURL(args: args) {
            UIApplication.shared.open(url)
        }
    }

    private func copyAddress() {
        guard let primary else { return }
        let text: String
        if let address = primary.address, !address.isEmpty {
            text = address
        } else if let lat = primary.latitude, let lon = primary.longitude {
            text = "\(lat), \(lon)"
        } else {
            text = primary.name
        }
        UIPasteboard.general.string = text
        copyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copyConfirmation = false
        }
    }

    private func resolvePins() async {
        let geocoder = CLGeocoder()
        var resolved: [MapPinItem] = []
        for (index, loc) in args.locations.enumerated() {
            if let lat = loc.latitude, let lon = loc.longitude, isValidCoordinate(latitude: lat, longitude: lon) {
                resolved.append(MapPinItem(
                    id: index,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    name: loc.name,
                    subtitle: loc.description ?? loc.address
                ))
                continue
            }
            let query = loc.address ?? loc.name
            guard !query.isEmpty else { continue }
            do {
                let placemarks = try await geocoder.geocodeAddressString(query)
                if let coord = placemarks.first?.location?.coordinate {
                    resolved.append(MapPinItem(
                        id: index,
                        coordinate: coord,
                        name: loc.name,
                        subtitle: loc.description ?? loc.address
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                // Geocoding can fail for ambiguous queries; skip silently —
                // the "Open in Apple Maps" button still works because Apple
                // Maps resolves the string itself.
                continue
            }
        }
        if Task.isCancelled { return }
        await MainActor.run {
            self.pins = resolved
            if !resolved.isEmpty {
                self.region = computeRegion(for: resolved)
            }
        }
    }

    private func computeRegion(for pins: [MapPinItem]) -> MKCoordinateRegion {
        guard !pins.isEmpty else { return region }
        if pins.count == 1 {
            return MKCoordinateRegion(
                center: pins[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let lats = pins.map(\.coordinate.latitude)
        let lons = pins.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return region }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.02),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.02)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - UIKit map bridge

private struct MapViewRepresentable: UIViewRepresentable {
    let region: MKCoordinateRegion
    let pins: [MapPinItem]
    let mapType: MKMapType

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.showsCompass = true
        view.isRotateEnabled = true
        view.isPitchEnabled = false
        view.mapType = mapType
        view.setRegion(region, animated: false)
        return view
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.mapType = mapType
        uiView.removeAnnotations(uiView.annotations)
        for pin in pins {
            let annotation = MKPointAnnotation()
            annotation.coordinate = pin.coordinate
            annotation.title = pin.name
            annotation.subtitle = pin.subtitle
            uiView.addAnnotation(annotation)
        }
        if !pins.isEmpty {
            uiView.setRegion(region, animated: false)
        }
    }
}
