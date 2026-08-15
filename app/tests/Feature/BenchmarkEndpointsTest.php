<?php

namespace Tests\Feature;

use Tests\TestCase;

class BenchmarkEndpointsTest extends TestCase
{
    public function test_health_endpoint_returns_no_content(): void
    {
        $this->get('/api/health')
            ->assertNoContent();
    }

    public function test_static_endpoint_returns_the_expected_payload(): void
    {
        $this->getJson('/api/static')
            ->assertOk()
            ->assertExactJson([
                'status' => true,
                'service' => 'laravel-runtime-benchmark',
                'version' => '1.0.0',
            ]);
    }

    public function test_cpu_endpoint_is_deterministic(): void
    {
        $this->getJson('/api/cpu')
            ->assertOk()
            ->assertExactJson([
                'checksum' => 764380,
                'items' => 1000,
            ]);
    }
}
