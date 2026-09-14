import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';
import nodemailer from 'nodemailer';
import { Config } from './config';
export class Delivery {
    constructor(private readonly config: Config) { }
    async send(target: string, channel: 'EMAIL' | 'MOBILE', code: string): Promise<void> {
        const message = `Your PDS verification code is ${code}. It expires in 10 minutes. Do not share this code.`;
        if (channel === 'MOBILE') {
            await new SNSClient({ region: this.config.AWS_REGION }).send(new PublishCommand({ PhoneNumber: target, Message: message, MessageAttributes: { 'AWS.SNS.SMS.SMSType': { DataType: 'String', StringValue: 'Transactional' } } }));
            return;
        }
        if (this.config.MAIL_MODE === 'ses') {
            await new SESv2Client({ region: this.config.AWS_REGION }).send(new SendEmailCommand({ FromEmailAddress: this.config.MAIL_FROM, Destination: { ToAddresses: [target] }, Content: { Simple: { Subject: { Data: 'PDS account verification' }, Body: { Text: { Data: message } } } } }));
        }
        else {
            await nodemailer.createTransport({ host: this.config.SMTP_HOST, port: this.config.SMTP_PORT, secure: false }).sendMail({ from: this.config.MAIL_FROM, to: target, subject: 'PDS account verification', text: message });
        }
    }
}

