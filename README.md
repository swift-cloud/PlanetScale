# PlanetScale

A [PlanetScale](https://planetscale.com) library compatible with all Apple platforms, Swift Cloud and Fastly Compute@Edge

## Usage

```swift
let client = PlanetscaleClient(username: "...", password: "...")

let rows = try await client.execute("select * from customers limit 10").json()
```
