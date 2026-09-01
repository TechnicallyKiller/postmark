import HookInterface from '@/components/HookInterface';

// HookInterface renders its own <main>. Wrapping it in a second one with padding nested a landmark
// inside a landmark and inset the whole app by 32px, which cropped the 2000px Flow canvas.
export default function Home() {
  return <HookInterface />;
}
