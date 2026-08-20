import Foundation

enum SharedImportRepresentation {
    case file(URL)
    case data(Data)
}

enum SharedImportRepresentationLoader {
    typealias FileLoader = (@escaping (URL?, Error?) -> Void) -> Void
    typealias DataLoader = (@escaping (Data?, Error?) -> Void) -> Void

    static func load(
        fileRepresentation: @escaping FileLoader,
        dataRepresentation: @escaping DataLoader,
        completion: @escaping (Result<SharedImportRepresentation, Error>) -> Void
    ) {
        fileRepresentation { url, fileError in
            if let url {
                completion(.success(.file(url)))
                return
            }

            // Apple provides no streaming Data representation API. Prefer a
            // file, then enforce limits as soon as fallback Data materializes.
            dataRepresentation { data, dataError in
                if let data {
                    completion(.success(.data(data)))
                } else {
                    completion(.failure(dataError ?? fileError ?? SharedImportError.invalidFile))
                }
            }
        }
    }
}
