/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
package net.runelite.client.headless;

import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.Clip;
import javax.sound.sampled.Control;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.Line;
import javax.sound.sampled.LineListener;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.SourceDataLine;
import javax.sound.sampled.spi.MixerProvider;

/**
 * Registered through {@code META-INF/services}, so {@link AudioSystem#getLine} finds it. Offers one mixer on a
 * device with a {@link HeadlessAudio.Sink} and none anywhere else. See {@link HeadlessAudio}.
 */
public final class HeadlessMixerProvider extends MixerProvider
{
	private static final Mixer.Info INFO = new Mixer.Info("Rune Mobile", "Rune Mobile", "Game audio output", "1")
	{
	};

	/** What a line takes: the engine's format is 22050 Hz stereo, and the system converts the rate. */
	private static final AudioFormat[] FORMATS = {
		new AudioFormat(AudioFormat.Encoding.PCM_SIGNED, AudioSystem.NOT_SPECIFIED, 16, 1, 2,
			AudioSystem.NOT_SPECIFIED, false),
		new AudioFormat(AudioFormat.Encoding.PCM_SIGNED, AudioSystem.NOT_SPECIFIED, 16, 2, 4,
			AudioSystem.NOT_SPECIFIED, false),
	};

	private static final DataLine.Info SOURCE_LINE = new DataLine.Info(SourceDataLine.class, FORMATS,
		AudioSystem.NOT_SPECIFIED, AudioSystem.NOT_SPECIFIED);

	/** A clip converts whatever it is given, so it takes every format. */
	private static final DataLine.Info CLIP = new DataLine.Info(Clip.class, FORMATS, AudioSystem.NOT_SPECIFIED,
		AudioSystem.NOT_SPECIFIED);

	private static final Mixer MIXER = new HeadlessMixer();

	@Override
	public Mixer.Info[] getMixerInfo()
	{
		return HeadlessAudio.sink() != null ? new Mixer.Info[]{INFO} : new Mixer.Info[0];
	}

	@Override
	public Mixer getMixer(Mixer.Info info)
	{
		if (info != null && !INFO.equals(info))
		{
			throw new IllegalArgumentException("not ours: " + info);
		}
		return MIXER;
	}

	static boolean isPlayable(AudioFormat format)
	{
		return AudioFormat.Encoding.PCM_SIGNED.equals(format.getEncoding())
			&& format.getSampleSizeInBits() == 16
			&& !format.isBigEndian()
			&& (format.getChannels() == 1 || format.getChannels() == 2)
			&& format.getSampleRate() > 0;
	}

	private static final class HeadlessMixer implements Mixer
	{
		@Override
		public Mixer.Info getMixerInfo()
		{
			return INFO;
		}

		@Override
		public Line.Info[] getSourceLineInfo()
		{
			return new Line.Info[]{SOURCE_LINE, CLIP};
		}

		@Override
		public Line.Info[] getTargetLineInfo()
		{
			return new Line.Info[0];
		}

		@Override
		public Line.Info[] getSourceLineInfo(Line.Info info)
		{
			return isLineSupported(info) ? new Line.Info[]{info} : new Line.Info[0];
		}

		@Override
		public Line.Info[] getTargetLineInfo(Line.Info info)
		{
			return new Line.Info[0];
		}

		@Override
		public boolean isLineSupported(Line.Info info)
		{
			if (!(info instanceof DataLine.Info))
			{
				return false;
			}
			if (Clip.class.equals(info.getLineClass()))
			{
				return true;
			}
			if (!SourceDataLine.class.equals(info.getLineClass()))
			{
				return false;
			}
			for (AudioFormat format : ((DataLine.Info) info).getFormats())
			{
				if (!matches(format))
				{
					return false;
				}
			}
			return true;
		}

		private static boolean matches(AudioFormat wanted)
		{
			for (AudioFormat format : FORMATS)
			{
				if (wanted.matches(format))
				{
					return true;
				}
			}
			return false;
		}

		@Override
		public Line getLine(Line.Info info) throws LineUnavailableException
		{
			if (!isLineSupported(info))
			{
				throw new IllegalArgumentException("not supported: " + info);
			}
			DataLine.Info wanted = (DataLine.Info) info;
			if (Clip.class.equals(wanted.getLineClass()))
			{
				return new HeadlessAudioClip(wanted);
			}
			AudioFormat[] formats = wanted.getFormats();
			AudioFormat format = formats.length > 0 ? formats[0] : null;
			if (format == null || !isPlayable(format))
			{
				format = new AudioFormat(22050f, 16, 2, true, false);
			}
			return new HeadlessAudioLine(wanted, format);
		}

		@Override
		public int getMaxLines(Line.Info info)
		{
			return isLineSupported(info) ? AudioSystem.NOT_SPECIFIED : 0;
		}

		@Override
		public Line[] getSourceLines()
		{
			return new Line[0];
		}

		@Override
		public Line[] getTargetLines()
		{
			return new Line[0];
		}

		@Override
		public void synchronize(Line[] lines, boolean maintainSync)
		{
			throw new IllegalArgumentException("lines can't be synchronized");
		}

		@Override
		public void unsynchronize(Line[] lines)
		{
			throw new IllegalArgumentException("lines can't be synchronized");
		}

		@Override
		public boolean isSynchronizationSupported(Line[] lines, boolean maintainSync)
		{
			return false;
		}

		@Override
		public Line.Info getLineInfo()
		{
			return new Line.Info(Mixer.class);
		}

		@Override
		public void open()
		{
		}

		@Override
		public void close()
		{
		}

		@Override
		public boolean isOpen()
		{
			return true;
		}

		@Override
		public Control[] getControls()
		{
			return new Control[0];
		}

		@Override
		public boolean isControlSupported(Control.Type control)
		{
			return false;
		}

		@Override
		public Control getControl(Control.Type control)
		{
			throw new IllegalArgumentException("unsupported control: " + control);
		}

		@Override
		public void addLineListener(LineListener listener)
		{
		}

		@Override
		public void removeLineListener(LineListener listener)
		{
		}
	}
}
